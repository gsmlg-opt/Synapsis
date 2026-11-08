defmodule Synapsis.Workspace.ClawRouterAudioFormatsFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Workspace.Media

  @moduletag :tmp_dir
  @audio "fixture8"

  # Opaque byte-storage evidence only. Labels make no codec or playback claim.
  # AAC exercises the new mapping/URI; the other five source formats regress it.
  for {format, mime} <- [
        {"mp3", "audio/mpeg"},
        {"opus", "audio/ogg"},
        {"aac", "audio/aac"},
        {"flac", "audio/flac"},
        {"wav", "audio/wav"},
        {"pcm", "application/octet-stream"}
      ] do
    @format format
    @mime mime

    test "#{format} exact bytes and five-field descriptor survive ordinary other-process rereads",
         %{tmp_dir: root} do
      sha = Base.encode16(:crypto.hash(:sha256, @audio), case: :lower)

      descriptor = %{
        "uri" => "synapsis-media://audio/#{sha}.#{@format}",
        "sha256" => sha,
        "byte_size" => 8,
        "mime_type" => @mime,
        "format" => @format
      }

      assert {:ok, ^descriptor} = Media.put_audio(@audio, @format, root: root)
      assert Jason.decode!(Jason.encode!(descriptor)) == descriptor
      assert [path] = Path.wildcard(Path.join(root, "**/*.#{@format}"))
      assert Path.extname(path) == "." <> @format
      assert File.read!(path) == @audio
      original = File.stat!(path, time: :posix)

      for _ <- 1..2 do
        reader = Task.async(fn -> Media.read_audio(descriptor["uri"], root: root) end)
        assert {:ok, %{audio: @audio, descriptor: ^descriptor}} = Task.await(reader, 5_000)
        assert {:ok, ^descriptor} = Media.put_audio(@audio, @format, root: root)
        current = File.stat!(path, time: :posix)

        assert {current.inode, current.mtime, current.size} ==
                 {original.inode, original.mtime, original.size}

        assert File.read!(path) == @audio
      end
    end
  end
end
