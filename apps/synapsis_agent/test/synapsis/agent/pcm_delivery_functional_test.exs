defmodule Synapsis.Agent.PCMDeliveryFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.MediaDelivery
  alias Synapsis.Runtime.Store
  alias Synapsis.Workspace.Media

  @moduletag :tmp_dir
  @audio <<255, 0, 128, "opaque PCM delivery", 0, 7>>

  test "PCM uses the existing three-field delivery reference and original-root private fact", %{
    tmp_dir: root
  } do
    id = Ecto.UUID.generate()
    media_root = Path.join(root, "original-pcm")
    max_bytes = 4_096

    operation = %{
      run_id: Ecto.UUID.generate(),
      invocation_id: Ecto.UUID.generate(),
      tool_call_id: "ordinary-pcm",
      tool_name: "synapsis::tts"
    }

    assert {:ok, descriptor} = Media.put_audio(@audio, "pcm", root: media_root)
    sha = Base.encode16(:crypto.hash(:sha256, @audio), case: :lower)

    assert descriptor == %{
             "uri" => "synapsis-media://audio/#{sha}.pcm",
             "sha256" => sha,
             "byte_size" => byte_size(@audio),
             "mime_type" => "application/octet-stream",
             "format" => "pcm"
           }

    assert {:ok, reference} =
             MediaDelivery.publish(descriptor, id, operation,
               root: media_root,
               max_bytes: max_bytes
             )

    assert %{"version" => 1, "session_id" => ^id, "id" => delivery_id} = reference
    assert map_size(reference) == 3
    assert {:ok, ^delivery_id} = Ecto.UUID.cast(delivery_id)
    assert {:ok, "/api/media/audio/" <> path} = MediaDelivery.url(reference)
    assert path == id <> "/" <> delivery_id
    assert {:ok, fact} = Store.get_fact(id, :audio_delivery, delivery_id)

    assert fact == %{
             version: 1,
             descriptor: descriptor,
             root: Path.expand(media_root),
             max_bytes: max_bytes,
             invocation: operation
           }

    assert [file] = Path.wildcard(Path.join(media_root, "**/*.pcm"))
    original = File.stat!(file, time: :posix)

    for _ <- 1..2 do
      reader = Task.async(fn -> MediaDelivery.read(id, delivery_id) end)
      assert {:ok, %{audio: @audio, descriptor: ^descriptor}} = Task.await(reader, 5_000)
      assert {:ok, ^fact} = Store.get_fact(id, :audio_delivery, delivery_id)
      current = File.stat!(file, time: :posix)

      assert {current.inode, current.mtime, current.size} ==
               {original.inode, original.mtime, original.size}
    end

    assert {:ok, [^fact]} = Store.list_facts(id, :audio_delivery)
  end
end
