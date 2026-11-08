defmodule Synapsis.Workspace.AzureAudioFormatsFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Workspace.Media

  @moduletag :tmp_dir
  @audio <<0, 1, 2, 254, 255>>

  # These are byte-storage tests; the format label does not imply codec validation.
  for {format, mime} <- [
        {"ogg", "audio/ogg"},
        {"webm", "audio/webm"},
        {"amr", "audio/amr"},
        {"audio", "application/octet-stream"},
        {"mp3", "audio/mpeg"},
        {"opus", "audio/ogg"},
        {"wav", "audio/wav"},
        {"pcm", "application/octet-stream"},
        {"flac", "audio/flac"}
      ] do
    @format format
    @mime mime

    test "#{format} stores and rereads exact bytes with its original extension and five-field descriptor",
         %{tmp_dir: root} do
      sha = Base.encode16(:crypto.hash(:sha256, @audio), case: :lower)

      expected = %{
        "uri" => "synapsis-media://audio/#{sha}.#{@format}",
        "sha256" => sha,
        "byte_size" => byte_size(@audio),
        "mime_type" => @mime,
        "format" => @format
      }

      assert {:ok, ^expected} = Media.put_audio(@audio, @format, root: root)
      assert Jason.decode!(Jason.encode!(expected)) == expected
      assert [path] = Path.wildcard(Path.join(root, "**/*.#{@format}"))
      assert Path.extname(path) == "." <> @format
      original = File.stat!(path, time: :posix)

      for _ <- 1..2 do
        reader = Task.async(fn -> Media.read_audio(expected["uri"], root: root) end)
        assert {:ok, %{audio: @audio, descriptor: ^expected}} = Task.await(reader, 5_000)
        assert File.read!(path) == @audio
        current = File.stat!(path, time: :posix)

        assert {current.inode, current.mtime, current.size} ==
                 {original.inode, original.mtime, original.size}
      end
    end
  end

  test "Ogg and Opus retain different URI and file extensions for identical bytes", %{
    tmp_dir: root
  } do
    assert {:ok, ogg} = Media.put_audio(@audio, "ogg", root: root)
    assert {:ok, opus} = Media.put_audio(@audio, "opus", root: root)
    assert ogg["mime_type"] == "audio/ogg"
    assert opus["mime_type"] == "audio/ogg"
    assert ogg["sha256"] == opus["sha256"]
    assert ogg["uri"] == "synapsis-media://audio/#{ogg["sha256"]}.ogg"
    assert opus["uri"] == "synapsis-media://audio/#{opus["sha256"]}.opus"
    assert [_] = Path.wildcard(Path.join(root, "**/*.ogg"))
    assert [_] = Path.wildcard(Path.join(root, "**/*.opus"))
    assert {:ok, %{audio: @audio, descriptor: ^ogg}} = Media.read_audio(ogg["uri"], root: root)
    assert {:ok, %{audio: @audio, descriptor: ^opus}} = Media.read_audio(opus["uri"], root: root)
  end
end
