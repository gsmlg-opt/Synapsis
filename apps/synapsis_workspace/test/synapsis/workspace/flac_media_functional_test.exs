defmodule Synapsis.Workspace.FLACMediaFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Workspace.Media

  @moduletag :tmp_dir
  # Opaque bytes establish storage identity, not a decodable FLAC stream.
  @audio <<"fLaC", 0, 255, 128, "ordinary immutable FLAC", 0, 254, 17>>

  test "FLAC retains exact portable metadata and immutable bytes across repeated publication and reads",
       %{tmp_dir: root} do
    sha = Base.encode16(:crypto.hash(:sha256, @audio), case: :lower)

    expected = %{
      "uri" => "synapsis-media://audio/#{sha}.flac",
      "sha256" => sha,
      "byte_size" => byte_size(@audio),
      "mime_type" => "audio/flac",
      "format" => "flac"
    }

    assert {:ok, ^expected} = Media.put_audio(@audio, "flac", root: root)
    assert Jason.decode!(Jason.encode!(expected)) == expected
    assert [path] = Path.wildcard(Path.join(root, "**/*.flac"))
    original = File.stat!(path, time: :posix)

    for _ <- 1..2 do
      assert {:ok, ^expected} = Media.put_audio(@audio, "flac", root: root)
      reader = Task.async(fn -> Media.read_audio(expected["uri"], root: root) end)
      assert {:ok, %{audio: @audio, descriptor: ^expected}} = Task.await(reader, 5_000)
      assert File.read!(path) == @audio
      current = File.stat!(path, time: :posix)

      assert {current.inode, current.mtime, current.size} ==
               {original.inode, original.mtime, original.size}
    end
  end
end
