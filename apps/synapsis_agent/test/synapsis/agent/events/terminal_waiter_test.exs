defmodule Synapsis.Agent.Events.TerminalWaiterTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.Events.{Emitter, RunEvent, TerminalWaiter}

  test "await receives typed completion in the subscribing process" do
    session_id = "waiter-#{System.unique_integer([:positive])}"

    task =
      Task.async(fn ->
        TerminalWaiter.await_after(session_id, [timeout_ms: 5_000], fn ->
          Emitter.emit_session_completed(session_id)
          :ok
        end)
      end)

    assert {:completed, %RunEvent{type: "session.completed", session_id: ^session_id}} =
             Task.await(task, 5_000)
  end

  test "await treats duplicate event_id as idempotent and keeps waiting for first match only once" do
    session_id = "waiter-dup-#{System.unique_integer([:positive])}"
    event = RunEvent.new("session.completed", session_id: session_id, event_id: "same-id")

    task =
      Task.async(fn ->
        TerminalWaiter.await(session_id,
          timeout_ms: 2_000,
          seen_event_ids: MapSet.new(["same-id"])
        )
      end)

    # Give the waiter time to subscribe.
    Process.sleep(50)
    Phoenix.PubSub.broadcast(Synapsis.PubSub, "session:#{session_id}", {:run_event, event})

    # Duplicate seen id is ignored; waiter times out rather than completing twice.
    assert {:waiter_timeout, _} = Task.await(task, 5_000)
  end

  test "await ignores turn_completed and wrong-session terminals" do
    session_id = "waiter-corr-#{System.unique_integer([:positive])}"
    other_id = "other-#{System.unique_integer([:positive])}"

    task =
      Task.async(fn ->
        TerminalWaiter.await(session_id, timeout_ms: 2_000)
      end)

    Process.sleep(50)
    Emitter.emit_turn_completed(session_id)
    Emitter.emit_session_completed(other_id)
    Emitter.emit_session_failed(session_id, "real failure")

    assert {:failed, %RunEvent{type: "session.failed", session_id: ^session_id}} =
             Task.await(task, 5_000)
  end

  test "await rejects mismatched run_id" do
    session_id = "waiter-run-#{System.unique_integer([:positive])}"

    task =
      Task.async(fn ->
        TerminalWaiter.await(session_id, timeout_ms: 1_500, run_id: "run-a")
      end)

    Process.sleep(50)
    Emitter.emit_session_completed(session_id, run_id: "run-b")
    assert {:waiter_timeout, _} = Task.await(task, 5_000)
  end
end
