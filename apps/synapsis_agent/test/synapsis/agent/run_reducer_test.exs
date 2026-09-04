defmodule Synapsis.Agent.RunReducerTest do
  use ExUnit.Case, async: true

  alias Synapsis.Agent.Events.RunEvent
  alias Synapsis.Agent.RunReducer
  alias Synapsis.Agent.RunState
  alias Synapsis.AgentRun

  defp run(attrs \\ %{}) do
    AgentRun.from_store(
      Map.merge(
        %{
          id: "run-r1",
          kind: "manual",
          status: "queued",
          source: "web",
          prompt: "hi",
          tool_profile: "read_only",
          last_event_sequence: 0,
          revision: 0,
          recovery_state: %{}
        },
        attrs
      )
    )
  end

  defp event(type, attrs) do
    RunEvent.new(
      type,
      Keyword.merge(
        [run_id: "run-r1", sequence: 1, occurred_at: DateTime.utc_now(), payload: %{}],
        attrs
      )
    )
  end

  test "queued -> starting -> running -> completed" do
    state = RunState.from_run(run())

    assert {:ok, state} =
             RunReducer.reduce(state, event("run.starting", sequence: 1))

    assert RunState.status(state) == "starting"

    assert {:ok, state} =
             RunReducer.reduce(state, event("run.started", sequence: 2))

    assert RunState.status(state) == "running"

    assert {:ok, state} =
             RunReducer.reduce(
               state,
               event("run.completed", sequence: 3, payload: %{"summary" => "done"})
             )

    assert RunState.status(state) == "completed"
    assert state.run.summary == "done"
    assert state.run.revision == 3
  end

  test "invalid transition is rejected" do
    state = RunState.from_run(run(%{status: "queued", last_event_sequence: 0}))

    assert {:error, :invalid_transition} =
             RunReducer.reduce(state, event("run.completed", sequence: 1))
  end

  test "duplicate event_id is idempotent" do
    state = RunState.from_run(run())
    ev = event("run.starting", sequence: 1, event_id: "same")

    assert {:ok, state} = RunReducer.reduce(state, ev)
    assert {:ok, state2} = RunReducer.reduce(state, ev)
    assert state2.run.revision == state.run.revision
    assert RunState.status(state2) == "starting"
  end

  test "contradictory terminal is rejected" do
    state =
      RunState.from_run(
        run(%{
          status: "completed",
          last_event_sequence: 3,
          recovery_state: %{"applied_event_ids" => ["t1"]}
        })
      )

    assert {:error, :already_terminal} =
             RunReducer.reduce(
               state,
               event("run.failed", sequence: 4, event_id: "t2", payload: %{"error" => "x"})
             )
  end

  test "stale sequence is rejected" do
    state = RunState.from_run(run(%{last_event_sequence: 5}))

    assert {:error, :stale_sequence} =
             RunReducer.reduce(state, event("run.starting", sequence: 5))
  end

  test "side_effect_intent marks recovery_state without status change" do
    state =
      RunState.from_run(run(%{status: "running", last_event_sequence: 2}))

    assert {:ok, state} =
             RunReducer.reduce(state, event("run.side_effect_intent", sequence: 3))

    assert RunState.status(state) == "running"
    assert state.run.recovery_state["side_effect_intent"] == true
  end

  test "waiting_approval and resume" do
    state =
      RunState.from_run(run(%{status: "running", last_event_sequence: 2}))

    assert {:ok, state} =
             RunReducer.reduce(state, event("run.waiting_approval", sequence: 3))

    assert {:ok, state} =
             RunReducer.reduce(state, event("run.resumed", sequence: 4))

    assert RunState.status(state) == "running"
  end
end
