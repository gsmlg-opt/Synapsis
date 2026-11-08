defmodule Synapsis.Agent.MediaDeliveryFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.MediaDelivery
  alias Synapsis.Runtime.Store
  alias Synapsis.Workspace.Media

  @moduletag :tmp_dir
  @moduletag timeout: 90_000

  test "distinct native invocations sharing a provider call ID publish independent durable references",
       %{tmp_dir: root} do
    session_id = Ecto.UUID.generate()
    media_root = Path.join(root, "original-audio")
    audio = "ordinary immutable speech bytes"
    max_bytes = 1_024
    assert {:ok, descriptor} = Media.put_audio(audio, "wav", root: media_root)
    first_invocation = invocation("reused-provider-call")
    second_invocation = invocation("reused-provider-call")

    assert {:ok, first} =
             MediaDelivery.publish(descriptor, session_id, first_invocation,
               root: media_root,
               max_bytes: max_bytes
             )

    assert {:ok, second} =
             MediaDelivery.publish(descriptor, session_id, second_invocation,
               root: media_root,
               max_bytes: max_bytes
             )

    assert first != second

    for {reference, native} <- [{first, first_invocation}, {second, second_invocation}] do
      assert %{"version" => 1, "session_id" => ^session_id, "id" => id} = reference
      assert map_size(reference) == 3
      assert {:ok, ^id} = Ecto.UUID.cast(id)
      assert {:ok, "/api/media/audio/" <> path} = MediaDelivery.url(reference)
      assert path == session_id <> "/" <> id

      assert {:ok, fact} = Store.get_fact(session_id, :audio_delivery, id)

      assert fact == %{
               version: 1,
               descriptor: descriptor,
               root: Path.expand(media_root),
               max_bytes: max_bytes,
               invocation: Map.take(native, [:run_id, :invocation_id, :tool_call_id, :tool_name])
             }

      reader = Task.async(fn -> MediaDelivery.read(session_id, id) end)
      assert {:ok, %{audio: ^audio, descriptor: ^descriptor}} = Task.await(reader, 10_000)
      assert {:ok, ^fact} = Store.get_fact(session_id, :audio_delivery, id)
    end

    assert {:ok, [_, _]} = Store.list_facts(session_id, :audio_delivery)
  end

  test "repeated reads retain the original custom root and a configured bound above 16 MiB",
       %{tmp_dir: root} do
    session_id = Ecto.UUID.generate()
    media_root = Path.join(root, "custom-audio")
    audio = :binary.copy(<<0, 1>>, 8 * 1024 * 1024 + 1)
    max_bytes = byte_size(audio) + 1_024
    assert byte_size(audio) > 16 * 1024 * 1024

    assert {:ok, descriptor} =
             Media.put_audio(audio, "wav", root: media_root, max_bytes: max_bytes)

    assert {:ok, reference} =
             MediaDelivery.publish(descriptor, session_id, invocation("large-audio"),
               root: media_root,
               max_bytes: max_bytes
             )

    assert [path] = Path.wildcard(Path.join(media_root, "**/*.wav"))
    original = File.stat!(path, time: :posix)
    assert {:ok, fact} = Store.get_fact(session_id, :audio_delivery, reference["id"])
    assert fact.root == Path.expand(media_root)
    assert fact.max_bytes == max_bytes

    for _ <- 1..2 do
      reader = Task.async(fn -> MediaDelivery.read(session_id, reference["id"]) end)
      assert {:ok, %{audio: ^audio, descriptor: ^descriptor}} = Task.await(reader, 10_000)
      assert {:ok, ^fact} = Store.get_fact(session_id, :audio_delivery, reference["id"])
      current = File.stat!(path, time: :posix)

      assert {current.inode, current.mtime, current.size} ==
               {original.inode, original.mtime, original.size}
    end

    assert {:ok, [^fact]} = Store.list_facts(session_id, :audio_delivery)
  end

  defp invocation(tool_call_id) do
    %{
      run_id: Ecto.UUID.generate(),
      invocation_id: Ecto.UUID.generate(),
      tool_call_id: tool_call_id,
      tool_name: "synapsis::tts",
      arguments: %{"text" => "Invocation-local input is not stored in delivery facts"}
    }
  end
end
