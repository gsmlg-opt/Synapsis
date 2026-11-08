defmodule Synapsis.Workspace.MediaFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Workspace.Media

  @moduletag :tmp_dir
  @default_max_bytes 16 * 1024 * 1024

  test "stores exact WAV bytes with deterministic portable metadata", %{tmp_dir: root} do
    audio = wav()
    expected = descriptor(audio, "wav", "audio/wav")

    assert {:ok, ^expected} = Media.put_audio(audio, "wav", root: root)

    assert {:ok, %{audio: ^audio, descriptor: ^expected}} =
             Media.read_audio(expected["uri"], root: root)

    assert Jason.decode!(Jason.encode!(expected)) == expected
    assert File.read!(stored_path(root, expected)) == audio
    assert artifacts(root) == [stored_path(root, expected)]
  end

  test "roundtrips opaque MP3 and Opus bytes without decoding", %{tmp_dir: root} do
    for {format, mime_type, audio} <- [
          {"mp3", "audio/mpeg", <<0, 255, 128, "opaque MP3", 0, 254>>},
          {"opus", "audio/ogg", <<255, 0, 129, "opaque Opus", 0, 253>>}
        ] do
      expected = descriptor(audio, format, mime_type)

      assert {:ok, ^expected} = Media.put_audio(audio, format, root: root)

      assert {:ok, %{audio: ^audio, descriptor: ^expected}} =
               Media.read_audio(expected["uri"], root: root)

      assert File.read!(stored_path(root, expected)) == audio
    end
  end

  test "duplicate publication preserves the published inode modification time and bytes", %{
    tmp_dir: root
  } do
    audio = wav()
    assert {:ok, expected} = Media.put_audio(audio, "wav", root: root)
    path = stored_path(root, expected)
    :ok = File.touch(path, {{2020, 1, 2}, {3, 4, 5}})
    before = File.stat!(path, time: :posix)

    assert {:ok, ^expected} = Media.put_audio(audio, "wav", root: root)

    after_publication = File.stat!(path, time: :posix)
    assert after_publication.inode == before.inode
    assert after_publication.mtime == before.mtime
    assert File.read!(path) == audio
    assert artifacts(root) == [path]
  end

  test "concurrent completed puts publish one canonical artifact and clean temporary files", %{
    tmp_dir: root
  } do
    audio = :binary.copy(<<0, 255, 42, 128>>, 16_384)
    expected = descriptor(audio, "opus", "audio/ogg")

    writers =
      for _ <- 1..12 do
        Task.async(fn ->
          receive do
            :publish -> Media.put_audio(audio, "opus", root: root)
          end
        end)
      end

    Enum.each(writers, &send(&1.pid, :publish))
    assert Enum.map(writers, &Task.await(&1, 10_000)) == List.duplicate({:ok, expected}, 12)
    assert artifacts(root) == [stored_path(root, expected)]

    assert {:ok, %{audio: ^audio, descriptor: ^expected}} =
             Media.read_audio(expected["uri"], root: root)
  end

  test "an independent process reads a JSON reference after the writer exits", %{tmp_dir: root} do
    owner = self()
    audio = wav()
    expected = descriptor(audio, "wav", "audio/wav")

    {writer, writer_monitor} =
      spawn_monitor(fn ->
        {:ok, metadata} = Media.put_audio(audio, "wav", root: root)
        send(owner, {:persisted_audio, Jason.encode!(metadata)})
      end)

    assert_receive {:persisted_audio, json}, 5_000
    assert_receive {:DOWN, ^writer_monitor, :process, ^writer, :normal}, 5_000

    {reader, reader_monitor} =
      spawn_monitor(fn ->
        metadata = Jason.decode!(json)
        send(owner, {:reopened_audio, Media.read_audio(metadata["uri"], root: root)})
      end)

    assert_receive {:reopened_audio, {:ok, %{audio: ^audio, descriptor: ^expected}}}, 5_000
    assert_receive {:DOWN, ^reader_monitor, :process, ^reader, :normal}, 5_000
    assert artifacts(root) == [stored_path(root, expected)]
  end

  test "accepts binary storage exactly at the default byte limit", %{tmp_dir: root} do
    audio = :binary.copy(<<255, 0, 128, 1>>, div(@default_max_bytes, 4))
    expected = descriptor(audio, "mp3", "audio/mpeg")

    assert {:ok, ^expected} = Media.put_audio(audio, "mp3", root: root)

    assert {:ok, %{audio: ^audio, descriptor: ^expected}} =
             Media.read_audio(expected["uri"], root: root)

    assert expected["byte_size"] == @default_max_bytes
  end

  test "explicit isolated roots and nominal deadlines preserve independent media", %{
    tmp_dir: tmp_dir
  } do
    audio = wav()
    expected = descriptor(audio, "wav", "audio/wav")
    roots = Enum.map(["first-host", "second-host"], &Path.join(tmp_dir, &1))

    for root <- roots do
      opts = [
        root: root,
        max_bytes: byte_size(audio),
        deadline: System.monotonic_time(:millisecond) + 30_000
      ]

      assert {:ok, ^expected} = Media.put_audio(audio, "wav", opts)

      assert {:ok, %{audio: ^audio, descriptor: ^expected}} =
               Media.read_audio(expected["uri"], opts)

      assert artifacts(root) == [stored_path(root, expected)]
    end
  end

  defp wav do
    <<"RIFF", 40::little-32, "WAVEfmt ", 16::little-32, 1::little-16, 1::little-16,
      8_000::little-32, 16_000::little-32, 2::little-16, 16::little-16, "data", 4::little-32,
      0::little-signed-16, 1_024::little-signed-16>>
  end

  defp descriptor(audio, format, mime_type) do
    sha256 = :crypto.hash(:sha256, audio) |> Base.encode16(case: :lower)

    %{
      "uri" => "synapsis-media://audio/#{sha256}.#{format}",
      "sha256" => sha256,
      "byte_size" => byte_size(audio),
      "mime_type" => mime_type,
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
