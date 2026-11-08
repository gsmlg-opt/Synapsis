defmodule Synapsis.Workspace.VideoMediaFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Workspace.Media

  @moduletag :tmp_dir
  @moduletag timeout: 90_000
  @default_max_bytes 16 * 1024 * 1024
  # Opaque protocol bytes deliberately make no claim about video decoding.
  @video <<0, 255, 128, "opaque video protocol bytes", 0, 254, 1>>
  @sha256 "841e55287d500fd10de4ae708acdc9e6aabfcc558f4020a65581bf2054168a5b"
  @mime_cases [
    {"video/x-msvideo", "avi"},
    {"video/vnd.avi", "avi"},
    {"video/x-m4v", "m4v"},
    {"video/mp4", "mp4"},
    {"video/x-matroska", "mkv"},
    {"video/matroska", "mkv"},
    {"video/webm", "webm"},
    {"video/x-flv", "flv"},
    {"video/x-ms-wmv", "wmv"},
    {"video/quicktime", "mov"},
    {"VIDEO/MP4", "mp4"},
    {" \tVIDEO/X-MATROSKA \t; codecs=\"opaque\"; profile=1", "mkv"},
    {"\uFEFF\u00A0VIDEO/QUICKTIME\u2007 ; profile=opaque", "mov"},
    {"video/x-synapsis-opaque; vendor=retained", "mp4"}
  ]

  test "every MIME alias and fallback retains its exact original MIME and full descriptor", %{
    tmp_dir: root
  } do
    for {mime, format} <- @mime_cases do
      expected = descriptor(@video, format, mime)
      assert expected["sha256"] == @sha256
      assert {:ok, ^expected} = Media.put_video(@video, mime, root: root)
      assert map_size(expected) == 5
      assert Jason.decode!(Jason.encode!(expected)) == expected

      assert {:ok, %{video: @video, descriptor: ^expected}} =
               Media.read_video(expected, root: root)

      assert File.read!(stored_path(root, expected)) == @video
    end

    assert length(artifacts(root)) == 8
  end

  test "duplicate content and MIME aliases preserve the inode timestamp and original descriptors",
       %{
         tmp_dir: root
       } do
    original = descriptor(@video, "avi", "video/x-msvideo")
    alternate = descriptor(@video, "avi", "VIDEO/VND.AVI; profile=opaque")
    assert {:ok, ^original} = Media.put_video(@video, "video/x-msvideo", root: root)
    path = stored_path(root, original)
    :ok = File.touch(path, {{2020, 1, 2}, {3, 4, 5}})
    before = File.stat!(path, time: :posix)

    assert {:ok, ^original} = Media.put_video(@video, "video/x-msvideo", root: root)

    assert {:ok, ^alternate} =
             Media.put_video(@video, "VIDEO/VND.AVI; profile=opaque", root: root)

    assert original["uri"] == alternate["uri"]

    for expected <- [original, alternate] do
      assert {:ok, %{video: @video, descriptor: ^expected}} =
               Media.read_video(expected, root: root)
    end

    after_publication = File.stat!(path, time: :posix)
    assert {after_publication.inode, after_publication.mtime} == {before.inode, before.mtime}
    assert File.read!(path) == @video
    assert artifacts(root) == [path]
  end

  test "concurrent successful video publications retain one artifact without staging residue", %{
    tmp_dir: root
  } do
    expected = descriptor(@video, "webm", "video/webm")

    writers =
      for _ <- 1..12 do
        Task.async(fn ->
          receive do
            :publish -> Media.put_video(@video, "video/webm", root: root)
          end
        end)
      end

    Enum.each(writers, &send(&1.pid, :publish))
    assert Enum.map(writers, &Task.await(&1, 10_000)) == List.duplicate({:ok, expected}, 12)

    assert {:ok, %{video: @video, descriptor: ^expected}} =
             Media.read_video(expected, root: root)

    assert artifacts(root) == [stored_path(root, expected)]
  end

  test "a fresh process reads the lossless JSON descriptor after the publisher exits", %{
    tmp_dir: root
  } do
    owner = self()
    mime = "VIDEO/QUICKTIME; codecs=opaque"
    expected = descriptor(@video, "mov", mime)

    {writer, writer_monitor} =
      spawn_monitor(fn ->
        {:ok, metadata} = Media.put_video(@video, mime, root: root)
        send(owner, {:persisted_video, Jason.encode!(metadata)})
      end)

    assert_receive {:persisted_video, json}, 5_000
    assert_receive {:DOWN, ^writer_monitor, :process, ^writer, :normal}, 5_000

    {reader, reader_monitor} =
      spawn_monitor(fn ->
        send(owner, {:reopened_video, Media.read_video(Jason.decode!(json), root: root)})
      end)

    assert_receive {:reopened_video, {:ok, %{video: @video, descriptor: ^expected}}}, 5_000
    assert_receive {:DOWN, ^reader_monitor, :process, ^reader, :normal}, 5_000
    assert artifacts(root) == [stored_path(root, expected)]
  end

  test "stores and reads opaque video exactly at the default 16 MiB bound", %{tmp_dir: root} do
    video = :binary.copy(<<0, 255, 128, 1>>, div(@default_max_bytes, 4))
    expected = descriptor(video, "mp4", "video/mp4")

    assert {:ok, ^expected} = Media.put_video(video, "video/mp4", root: root)

    assert {:ok, %{video: ^video, descriptor: ^expected}} =
             Media.read_video(expected, root: root)

    assert expected["byte_size"] == @default_max_bytes
    assert artifacts(root) == [stored_path(root, expected)]
  end

  test "an explicit larger bound stores and reads video above 16 MiB", %{tmp_dir: root} do
    video = :binary.copy(<<0, 255>>, div(@default_max_bytes, 2) + 1)
    mime = "video/x-synapsis-opaque; profile=large"
    expected = descriptor(video, "mp4", mime)
    opts = [root: root, max_bytes: byte_size(video)]

    assert byte_size(video) == @default_max_bytes + 2
    assert {:ok, ^expected} = Media.put_video(video, mime, opts)
    assert {:ok, %{video: ^video, descriptor: ^expected}} = Media.read_video(expected, opts)
    assert artifacts(root) == [stored_path(root, expected)]
  end

  test "isolated roots honor exact byte bounds and an explicit nominal phase deadline", %{
    tmp_dir: tmp_dir
  } do
    expected = descriptor(@video, "m4v", "video/x-m4v; profile=opaque")

    for root <- Enum.map(["first-host", "second-host"], &Path.join(tmp_dir, &1)) do
      opts = [
        root: root,
        max_bytes: byte_size(@video),
        deadline: System.monotonic_time(:millisecond) + 30_000
      ]

      assert {:ok, ^expected} = Media.put_video(@video, "video/x-m4v; profile=opaque", opts)
      assert {:ok, %{video: @video, descriptor: ^expected}} = Media.read_video(expected, opts)
      assert artifacts(root) == [stored_path(root, expected)]
    end
  end

  defp descriptor(video, format, mime) do
    sha256 = :crypto.hash(:sha256, video) |> Base.encode16(case: :lower)

    %{
      "uri" => "synapsis-media://video/#{sha256}.#{format}",
      "sha256" => sha256,
      "byte_size" => byte_size(video),
      "format" => format,
      "mime_type" => mime
    }
  end

  defp stored_path(root, %{"sha256" => sha256, "format" => format}) do
    <<a::binary-size(2), b::binary-size(2), rest::binary>> = sha256
    Path.join([root, a, b, rest <> "." <> format])
  end

  defp artifacts(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
  end
end
