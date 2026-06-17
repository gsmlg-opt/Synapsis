defmodule Synapsis.Session.PendingInputStoreTest do
  use Synapsis.DataCase, async: false

  alias Synapsis.Session.PendingInputStore

  setup do
    session_id = Ecto.UUID.generate()

    on_exit(fn ->
      Synapsis.Session.Store.delete_session(session_id)
    end)

    {:ok, session_id: session_id}
  end

  test "stores queued prompts in FIFO order", %{session_id: session_id} do
    assert {:ok, first} = PendingInputStore.append_prompt(session_id, "first", [])
    assert {:ok, second} = PendingInputStore.append_prompt(session_id, "second", [])

    assert first.kind == "prompt"
    assert second.kind == "prompt"

    assert Enum.map(PendingInputStore.queued_prompts(session_id), & &1.content) == [
             "first",
             "second"
           ]
  end

  test "stores prompt image parts in the public and persisted shape", %{session_id: session_id} do
    image_parts = [
      %{
        "type" => "image",
        "media_type" => "image/png",
        "data" => "base64-data"
      }
    ]

    assert {:ok, input} = PendingInputStore.append_prompt(session_id, "see image", image_parts)

    assert input.image_parts == image_parts

    assert [%{image_parts: ^image_parts} = stored] =
             Synapsis.Session.Store.get_value(session_id, "pending_inputs", :missing)

    refute Map.has_key?(stored, :attachments)
  end

  test "stores steers separately from prompts", %{session_id: session_id} do
    assert {:ok, prompt} = PendingInputStore.append_prompt(session_id, "next turn", [])
    assert {:ok, steer} = PendingInputStore.append_steer(session_id, "use the current file")

    assert prompt.kind == "prompt"
    assert steer.kind == "steer"
    assert steer.image_parts == []
    assert Enum.map(PendingInputStore.queued_prompts(session_id), & &1.content) == ["next turn"]

    assert Enum.map(PendingInputStore.queued_steers(session_id), & &1.content) == [
             "use the current file"
           ]
  end

  test "takes and consumes the next prompt", %{session_id: session_id} do
    assert {:ok, input} = PendingInputStore.append_prompt(session_id, "queued", [])
    assert {:ok, ^input} = PendingInputStore.take_next_prompt(session_id)
    assert PendingInputStore.queued_prompts(session_id) == []

    assert :ok = PendingInputStore.mark_consumed(session_id, input.id)
    assert [%{status: "consumed"}] = PendingInputStore.list(session_id)
  end

  test "returns empty when there is no queued prompt", %{session_id: session_id} do
    assert :empty = PendingInputStore.take_next_prompt(session_id)
  end

  test "takes queued steers and marks them inflight", %{session_id: session_id} do
    assert {:ok, first} = PendingInputStore.append_steer(session_id, "one")
    assert {:ok, second} = PendingInputStore.append_steer(session_id, "two")

    assert [^first, ^second] = PendingInputStore.take_queued_steers(session_id)
    assert PendingInputStore.queued_steers(session_id) == []
    assert [%{status: "inflight"}, %{status: "inflight"}] = PendingInputStore.list(session_id)
  end

  test "does not rewrite storage when no queued steers exist", %{session_id: session_id} do
    raw_input = %{
      "id" => Ecto.UUID.generate(),
      "session_id" => session_id,
      "kind" => "steer",
      "status" => "consumed",
      "content" => "old",
      "image_parts" => [],
      "inserted_at" => "2026-01-01T00:00:00.000000Z",
      "updated_at" => "2026-01-01T00:00:00.000000Z",
      "unknown_field" => "preserve me"
    }

    assert :ok = Synapsis.Session.Store.put_value(session_id, "pending_inputs", [raw_input])

    assert [] = PendingInputStore.take_queued_steers(session_id)
    assert [^raw_input] = Synapsis.Session.Store.get_value(session_id, "pending_inputs", :missing)
  end

  test "recovers inflight prompts after worker restart", %{session_id: session_id} do
    assert {:ok, input} = PendingInputStore.append_prompt(session_id, "queued", [])
    assert {:ok, ^input} = PendingInputStore.take_next_prompt(session_id)
    assert :ok = PendingInputStore.recover_inflight(session_id)

    assert [%{id: id, status: "queued"}] = PendingInputStore.queued_prompts(session_id)
    assert id == input.id
  end

  test "cancels queued steers without cancelling prompts", %{session_id: session_id} do
    assert {:ok, _prompt} = PendingInputStore.append_prompt(session_id, "next turn", [])
    assert {:ok, steer} = PendingInputStore.append_steer(session_id, "now")

    assert :ok = PendingInputStore.cancel_steers(session_id)

    assert [%{content: "next turn"}] = PendingInputStore.queued_prompts(session_id)

    assert [%{id: id, status: "cancelled"}] =
             PendingInputStore.list(session_id) |> Enum.filter(&(&1.kind == "steer"))

    assert id == steer.id
  end

  test "keeps pending inputs isolated by session", %{session_id: session_id} do
    other_session_id = Ecto.UUID.generate()

    on_exit(fn ->
      Synapsis.Session.Store.delete_session(other_session_id)
    end)

    assert {:ok, _} = PendingInputStore.append_prompt(session_id, "first session", [])
    assert {:ok, _} = PendingInputStore.append_prompt(other_session_id, "second session", [])

    assert [%{content: "first session"}] = PendingInputStore.queued_prompts(session_id)
    assert [%{content: "second session"}] = PendingInputStore.queued_prompts(other_session_id)
  end

  test "enforces a pending input limit", %{session_id: session_id} do
    for index <- 1..25 do
      assert {:ok, _} = PendingInputStore.append_prompt(session_id, "prompt #{index}", [])
    end

    assert {:error, :queue_full} = PendingInputStore.append_prompt(session_id, "too many", [])
  end

  test "does not overwrite malformed stored pending inputs", %{session_id: session_id} do
    malformed = %{"not" => "a list"}

    assert :ok = Synapsis.Session.Store.put_value(session_id, "pending_inputs", malformed)

    assert {:error, :invalid_pending_inputs} =
             PendingInputStore.append_prompt(session_id, "new prompt", [])

    assert ^malformed = Synapsis.Session.Store.get_value(session_id, "pending_inputs", :missing)
  end
end
