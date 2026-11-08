defmodule Synapsis.Session.PromptProvenanceFunctionalTest do
  use Synapsis.DataCase, async: false

  alias Synapsis.Session.{PendingInputStore, Store}

  setup do
    session_id = Ecto.UUID.generate()
    on_exit(fn -> Store.delete_session(session_id) end)
    {:ok, session_id: session_id}
  end

  test "retains caller supplied IDs and opaque JSON through ordinary FIFO promotion and consumption",
       %{session_id: session_id} do
    first_id = Ecto.UUID.generate()
    second_id = Ecto.UUID.generate()
    first_provenance = provenance(session_id, first_id, "第一条")
    second_provenance = provenance(session_id, second_id, "第二条")
    images = [%{"type" => "image", "media_type" => "image/png", "data" => "fixture-data"}]

    assert {:ok, first} =
             PendingInputStore.append_prompt(session_id, "first prompt", images,
               id: first_id,
               input_provenance: first_provenance
             )

    assert {:ok, second} =
             PendingInputStore.append_prompt(session_id, "second prompt", [],
               id: second_id,
               input_provenance: second_provenance
             )

    assert first.id == first_id
    assert first.input_provenance == first_provenance
    assert first.image_parts == images
    assert second.id == second_id
    assert second.input_provenance == second_provenance
    assert {:ok, [^first, ^second]} = fresh_read(session_id)

    assert {:ok, ^first} = PendingInputStore.take_next_prompt(session_id)
    assert {:ok, [promoted_first, queued_second]} = fresh_read(session_id)

    assert {promoted_first.id, promoted_first.status, promoted_first.input_provenance} ==
             {first_id, "inflight", first_provenance}

    assert queued_second == second

    assert :ok = PendingInputStore.mark_consumed(session_id, first_id)
    assert {:ok, ^second} = PendingInputStore.take_next_prompt(session_id)
    assert :ok = PendingInputStore.mark_consumed(session_id, second_id)

    assert {:ok, consumed} = fresh_read(session_id)

    assert Enum.map(consumed, &{&1.id, &1.status, &1.input_provenance}) == [
             {first_id, "consumed", first_provenance},
             {second_id, "consumed", second_provenance}
           ]
  end

  test "retains the same identity and JSON across the ordinary recover and consume APIs",
       %{session_id: session_id} do
    input_id = Ecto.UUID.generate()
    captured = provenance(session_id, input_id, "恢复输入")

    assert {:ok, input} =
             PendingInputStore.append_prompt(session_id, "ordinary prompt", [],
               id: input_id,
               input_provenance: captured
             )

    assert {:ok, ^input} = PendingInputStore.take_next_prompt(session_id)
    assert :ok = PendingInputStore.recover_inflight(session_id)
    assert {:ok, [recovered]} = fresh_read(session_id)

    assert {recovered.id, recovered.status, recovered.input_provenance} ==
             {input_id, "queued", captured}

    assert {:ok, ^recovered} = PendingInputStore.take_next_prompt(session_id)
    assert :ok = PendingInputStore.mark_consumed(session_id, input_id)
    assert {:ok, [consumed]} = fresh_read(session_id)
    assert consumed.id == input_id
    assert consumed.status == "consumed"
    assert consumed.input_provenance == captured
    assert consumed.input_provenance |> Jason.encode!() |> Jason.decode!() == captured
  end

  defp fresh_read(session_id) do
    Task.async(fn -> PendingInputStore.list_result(session_id) end) |> Task.await()
  end

  defp provenance(session_id, input_id, label) do
    %{
      "version" => 1,
      "trigger" => "user",
      "provider" => "Fixture/聊天",
      "account_id" => "账户/Aa",
      "conversation_id" => "会话/Δ",
      "sender_id" => "发送者/É",
      "source_session_id" => session_id,
      "input_id" => input_id,
      "opaque_extension" => %{
        "label" => label,
        "values" => [true, nil, 7, 1.25, %{"literal" => " Keep Me "}]
      }
    }
  end
end
