defmodule Synapsis.Session.AutomationAppendFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Session.{PendingInputStore, Store}

  setup do
    assert :ok = Store.ensure_started()
    id = Ecto.UUID.generate()
    on_exit(fn -> Store.delete_session(id) end)
    %{id: id}
  end

  test "assistant receipt and transcript commit once together despite concurrent consumption", %{
    id: id
  } do
    meta = %{
      id: id,
      title: "Human title",
      config: %{"retained" => true},
      updated_at: DateTime.utc_now()
    }

    assert :ok = Store.put_meta(id, meta)
    assert {:ok, input} = PendingInputStore.append_assistant(id, "result", "stable-run")
    turn = %{id: input.id, role: "assistant", parts: [%{type: "text", text: "result"}]}

    tasks =
      for _ <- 1..2,
          do: Task.async(fn -> PendingInputStore.complete_assistant(id, input.id, turn) end)

    results = Enum.map(tasks, &Task.await(&1, 10_000))
    assert Enum.any?(results, &match?({:ok, 0, _}, &1))
    assert Enum.all?(results, &(match?({:ok, 0, _}, &1) or &1 == {:error, :unknown_outcome}))
    # A concurrent non-owner may only reconcile. The final receipt makes its
    # later retry a read, with the same original offset.
    assert {:ok, 0, _} = PendingInputStore.complete_assistant(id, input.id, turn)
    assert {:ok, [^turn]} = Store.list_turns(id)
    assert {:ok, current} = Store.get_meta(id)
    assert current.title == meta.title
    assert current.config == meta.config
    assert {:ok, receipt} = PendingInputStore.append_assistant(id, "result", "stable-run")
    assert receipt.id == input.id
    assert receipt.status == "consumed"
    assert receipt.content == nil
    # The persisted turn, metadata and receipt have one publication revision.
    revisions =
      for key <- [
            Store.turn_key(id, 0),
            Store.meta_key(id),
            Store.value_key(id, "pending_inputs")
          ] do
        assert {:ok, %{mod_revision: revision}} =
                 Concord.KV.get(key, engine: :turso, metadata: true)

        revision
      end

    assert [_, _, _] = revisions
    assert [_same_revision] = Enum.uniq(revisions)
  end

  test "an unresolved durable completion claim is read-only across owner recovery", %{id: id} do
    assert :ok = Store.put_meta(id, %{id: id, updated_at: DateTime.utc_now()})
    assert {:ok, input} = PendingInputStore.append_assistant(id, "ambiguous", "ambiguous-run")
    assert {:ok, snapshot = {:present, [entry], _}} = Store.read_pending_inputs(id)

    claimed =
      entry |> Map.put(:status, "inflight") |> Map.put(:completion_claim, Ecto.UUID.generate())

    assert :ok = Store.compare_put_pending_inputs(id, snapshot, [claimed])
    assert :ok = PendingInputStore.recover_for_owner(id, Ecto.UUID.generate())
    assert {:ok, before} = Store.read_pending_inputs(id)
    turn = %{id: input.id, role: "assistant", parts: [%{type: "text", text: "ambiguous"}]}

    assert {:error, :unknown_outcome} = PendingInputStore.complete_assistant(id, input.id, turn)
    assert {:ok, ^before} = Store.read_pending_inputs(id)
    assert {:ok, []} = Store.list_turns(id)

    assert {:ok, %{status: "inflight", id: message_id}} =
             PendingInputStore.append_assistant(id, "ambiguous", "ambiguous-run")

    assert message_id == input.id
  end

  test "known pre-dispatch rejection releases the claim for a later ordinary retry", %{id: id} do
    assert {:ok, input} = PendingInputStore.append_assistant(id, "retryable", "retryable-run")
    turn = %{id: input.id, role: "assistant", parts: [%{type: "text", text: "retryable"}]}
    assert {:error, :not_found} = PendingInputStore.complete_assistant(id, input.id, turn)
    assert [%{status: "queued", completion_claim: nil}] = PendingInputStore.list(id)
    assert :ok = Store.put_meta(id, %{id: id, updated_at: DateTime.utc_now()})
    assert {:ok, 0, _} = PendingInputStore.complete_assistant(id, input.id, turn)
    assert {:ok, [^turn]} = Store.list_turns(id)
  end

  test "expired assistant admission never acknowledges or creates a pending record", %{id: id} do
    assert {:error, :timeout} =
             PendingInputStore.append_assistant(id, "result", "run",
               deadline: System.monotonic_time(:millisecond) - 1
             )

    assert {:ok, []} = PendingInputStore.list_result(id)
  end

  test "completed assistant append preserves prior turns and all unrelated current metadata", %{
    id: id
  } do
    before = ~U[2026-10-28 01:00:00Z]
    now = ~U[2026-10-28 02:00:00Z]

    meta = %{
      id: id,
      title: "Updated title",
      config: %{"nested" => %{"keep" => true}},
      updated_at: before
    }

    previous = %{id: Ecto.UUID.generate(), role: "user", parts: [%{type: "text", text: "source"}]}

    result = %{
      id: Ecto.UUID.generate(),
      role: "assistant",
      parts: [%{type: "text", text: "作业已完成"}]
    }

    assert :ok = Store.commit_turn(id, 0, previous, meta)

    assert {:ok, merged} = Store.append_automation_turn(id, 1, result, now)
    assert merged == %{meta | updated_at: now}
    assert {:ok, ^merged} = Store.get_meta(id)
    assert {:ok, [^previous, ^result]} = Store.list_turns(id)
  end

  test "append reads the latest metadata after a separate title and config update", %{id: id} do
    original = %{
      id: id,
      title: "Original",
      config: %{"keep" => 1},
      updated_at: ~U[2026-10-28 01:00:00Z]
    }

    assert :ok = Store.put_meta(id, original)
    edited = %{original | title: "Human edit", config: %{"keep" => 1, "new" => "value"}}
    assert :ok = Store.put_meta(id, edited)

    turn = %{
      id: Ecto.UUID.generate(),
      role: "assistant",
      parts: [%{type: "text", text: "result"}]
    }

    now = ~U[2026-10-28 02:00:00Z]

    assert {:ok, meta} = Store.append_automation_turn(id, 0, turn, now)
    assert meta == %{edited | updated_at: now}
    assert {:ok, [^turn]} = Store.list_turns(id)
  end
end
