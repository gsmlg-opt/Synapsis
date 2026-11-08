defmodule Synapsis.Agent.FLACMediaDeliveryFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.MediaDelivery
  alias Synapsis.Runtime.Store
  alias Synapsis.Workspace.Media

  @moduletag :tmp_dir
  @audio <<"fLaC", 0, 255, 128, "ordinary original-root FLAC", 9>>

  test "FLAC durable reference retains its original root and exact immutable fact across process reads",
       %{tmp_dir: root} do
    session_id = Ecto.UUID.generate()
    media_root = Path.join(root, "original-audio")

    native = %{
      run_id: Ecto.UUID.generate(),
      invocation_id: Ecto.UUID.generate(),
      tool_call_id: "ordinary-flac-delivery",
      tool_name: "synapsis::tts"
    }

    max_bytes = 4_096
    sha = Base.encode16(:crypto.hash(:sha256, @audio), case: :lower)

    descriptor = %{
      "uri" => "synapsis-media://audio/#{sha}.flac",
      "sha256" => sha,
      "byte_size" => byte_size(@audio),
      "format" => "flac",
      "mime_type" => "audio/flac"
    }

    assert {:ok, ^descriptor} = Media.put_audio(@audio, "flac", root: media_root)

    assert {:ok, reference} =
             MediaDelivery.publish(descriptor, session_id, native,
               root: media_root,
               max_bytes: max_bytes
             )

    assert %{"version" => 1, "session_id" => ^session_id, "id" => id} = reference
    assert map_size(reference) == 3
    assert {:ok, ^id} = Ecto.UUID.cast(id)
    assert {:ok, "/api/media/audio/" <> path} = MediaDelivery.url(reference)
    assert path == session_id <> "/" <> id

    fact = %{
      version: 1,
      descriptor: descriptor,
      root: Path.expand(media_root),
      max_bytes: max_bytes,
      invocation: native
    }

    assert {:ok, ^fact} = Store.get_fact(session_id, :audio_delivery, id)
    assert [file] = Path.wildcard(Path.join(media_root, "**/*.flac"))
    original = File.stat!(file, time: :posix)

    for _ <- 1..2 do
      reader = Task.async(fn -> MediaDelivery.read(session_id, id) end)
      assert {:ok, %{audio: @audio, descriptor: ^descriptor}} = Task.await(reader, 5_000)
      assert {:ok, ^fact} = Store.get_fact(session_id, :audio_delivery, id)
      assert File.read!(file) == @audio
      current = File.stat!(file, time: :posix)

      assert {current.inode, current.mtime, current.size} ==
               {original.inode, original.mtime, original.size}
    end

    assert {:ok, [^fact]} = Store.list_facts(session_id, :audio_delivery)
  end
end
