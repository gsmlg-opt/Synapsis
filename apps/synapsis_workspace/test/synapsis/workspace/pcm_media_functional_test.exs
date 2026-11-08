defmodule Synapsis.Workspace.PCMMediaFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Workspace.Media

  @moduletag :tmp_dir
  @audio <<0, 255, 128, 3, "opaque PCM fixture", 0, 254, 17>>

  test "opaque PCM retains exact five-field metadata and immutable bytes on ordinary repeated reads",
       %{tmp_dir: root} do
    sha = Base.encode16(:crypto.hash(:sha256, @audio), case: :lower)

    expected = %{
      "uri" => "synapsis-media://audio/#{sha}.pcm",
      "sha256" => sha,
      "byte_size" => byte_size(@audio),
      "mime_type" => "application/octet-stream",
      "format" => "pcm"
    }

    assert {:ok, ^expected} = Media.put_audio(@audio, "pcm", root: root)
    assert Jason.decode!(Jason.encode!(expected)) == expected
    assert [path] = Path.wildcard(Path.join(root, "**/*.pcm"))
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
