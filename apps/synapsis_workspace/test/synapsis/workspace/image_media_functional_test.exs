defmodule Synapsis.Workspace.ImageMediaFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Workspace.Media

  @moduletag :tmp_dir
  @default_max_bytes 64 * 1024 * 1024
  # Exact tiny PNG/JPEG/WebP bytes from the fixed OpenClaw image protocol oracle.
  @fixtures [
    {"png", "image/png",
     "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jVJkAAAAASUVORK5CYII=",
     "dcd71be6609323b107bac1515f61b9a0cb146b41b05992cd4aaca98eed68e1e4"},
    {"jpeg", "image/jpeg",
     "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////2wBDAf//////////////////////////////////////////////////////////////////////////////////////wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAf/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIQAxAAAAF//8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABBQJ//8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAgBAwEBPwF//8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAgBAgEBPwF//8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQAGPwJ//8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPyF//9oADAMBAAIAAwAAABD/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAEDAQE/EH//xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAECAQE/EH//xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAE/EH//2Q==",
     "2d6fea12cf8376c0688aa12919e59f1ca7b25e01a05a7db78b094aadeae101bd"},
    {"webp", "image/webp", "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA",
     "c90cff659645a312a28804965f3dbc34061338f7234ff5d6ddb2c57e9eadec15"}
  ]

  test "stores each image format byte faithfully with its stable portable descriptor", %{
    tmp_dir: root
  } do
    for {format, mime, image, sha256} <- fixtures() do
      expected = descriptor(format, mime, image, sha256)
      assert {:ok, ^expected} = Media.put_image(image, format, root: root)
      assert Jason.decode!(Jason.encode!(expected)) == expected

      assert {:ok, %{image: ^image, descriptor: ^expected}} =
               Media.read_image(expected["uri"], root: root)

      assert File.read!(stored_path(root, expected)) == image
    end

    assert length(artifacts(root)) == 3
  end

  test "duplicate image publication retains the original inode timestamp and bytes", %{
    tmp_dir: root
  } do
    {format, mime, image, sha256} = hd(fixtures())
    expected = descriptor(format, mime, image, sha256)
    assert {:ok, ^expected} = Media.put_image(image, format, root: root)
    path = stored_path(root, expected)
    :ok = File.touch(path, {{2020, 1, 2}, {3, 4, 5}})
    before = File.stat!(path, time: :posix)

    assert {:ok, ^expected} = Media.put_image(image, format, root: root)

    after_publication = File.stat!(path, time: :posix)
    assert after_publication.inode == before.inode
    assert after_publication.mtime == before.mtime
    assert File.read!(path) == image
    assert artifacts(root) == [path]
  end

  test "concurrent successful image puts publish one artifact without staging residue", %{
    tmp_dir: root
  } do
    {format, mime, image, sha256} = List.last(fixtures())
    expected = descriptor(format, mime, image, sha256)

    writers =
      for _ <- 1..12 do
        Task.async(fn ->
          receive do
            :publish -> Media.put_image(image, format, root: root)
          end
        end)
      end

    Enum.each(writers, &send(&1.pid, :publish))
    assert Enum.map(writers, &Task.await(&1, 10_000)) == List.duplicate({:ok, expected}, 12)

    assert {:ok, %{image: ^image, descriptor: ^expected}} =
             Media.read_image(expected["uri"], root: root)

    assert artifacts(root) == [stored_path(root, expected)]
  end

  test "a fresh process reads a JSON reference after the image writer exits", %{tmp_dir: root} do
    owner = self()
    {format, mime, image, sha256} = Enum.at(fixtures(), 1)
    expected = descriptor(format, mime, image, sha256)

    {writer, writer_monitor} =
      spawn_monitor(fn ->
        {:ok, metadata} = Media.put_image(image, format, root: root)
        send(owner, {:persisted_image, Jason.encode!(metadata)})
      end)

    assert_receive {:persisted_image, json}, 5_000
    assert_receive {:DOWN, ^writer_monitor, :process, ^writer, :normal}, 5_000

    {reader, reader_monitor} =
      spawn_monitor(fn ->
        metadata = Jason.decode!(json)
        send(owner, {:reopened_image, Media.read_image(metadata["uri"], root: root)})
      end)

    assert_receive {:reopened_image, {:ok, %{image: ^image, descriptor: ^expected}}}, 5_000
    assert_receive {:DOWN, ^reader_monitor, :process, ^reader, :normal}, 5_000
    assert artifacts(root) == [stored_path(root, expected)]
  end

  test "stores opaque image bytes exactly at the default 64 MiB bound", %{tmp_dir: root} do
    image = :binary.copy(<<137, 80, 78, 71>>, div(@default_max_bytes, 4))
    assert {:ok, metadata} = Media.put_image(image, "png", root: root)
    assert metadata["byte_size"] == @default_max_bytes
    assert metadata["mime_type"] == "image/png"

    assert {:ok, %{image: ^image, descriptor: ^metadata}} =
             Media.read_image(metadata["uri"], root: root)

    assert artifacts(root) == [stored_path(root, metadata)]
  end

  test "isolated host roots accept exact image byte bounds and nominal phase deadlines", %{
    tmp_dir: tmp_dir
  } do
    for root <- Enum.map(["first-host", "second-host"], &Path.join(tmp_dir, &1)),
        {format, mime, image, sha256} <- fixtures() do
      expected = descriptor(format, mime, image, sha256)

      opts = [
        root: root,
        max_bytes: byte_size(image),
        deadline: System.monotonic_time(:millisecond) + 30_000
      ]

      assert {:ok, ^expected} = Media.put_image(image, format, opts)

      assert {:ok, %{image: ^image, descriptor: ^expected}} =
               Media.read_image(expected["uri"], opts)

      assert File.read!(stored_path(root, expected)) == image
    end
  end

  defp fixtures do
    Enum.map(@fixtures, fn {format, mime, encoded, sha256} ->
      {format, mime, Base.decode64!(encoded), sha256}
    end)
  end

  defp descriptor(format, mime, image, sha256) do
    %{
      "uri" => "synapsis-media://image/#{sha256}.#{format}",
      "sha256" => sha256,
      "byte_size" => byte_size(image),
      "mime_type" => mime,
      "format" => format
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
