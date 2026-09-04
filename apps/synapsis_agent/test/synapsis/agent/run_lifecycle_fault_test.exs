defmodule Synapsis.Agent.RunLifecycleFaultTest do
  use Synapsis.Agent.DataCase, async: false

  alias Synapsis.Agent.RunReconciler
  alias Synapsis.Agent.Runs

  setup do
    Synapsis.DataCase.clear_coord("coord/agent_runs/")
    Synapsis.DataCase.clear_coord("coord/agent_run_events/")
    Synapsis.DataCase.clear_coord("coord/agent_run_event_ids/")
    Synapsis.DataCase.clear_coord("coord/agent_run_idempotency/")
    Process.delete(:synapsis_agent_runs_put_result)
    Process.delete(:synapsis_run_events_put_result)
    :ok
  end

  @attrs %{
    kind: "manual",
    source: "system",
    prompt: "fault injection",
    tool_profile: "read_only"
  }

  test "crash before start fact leaves queued and reconciles to failed" do
    assert {:ok, run} = Runs.create(@attrs)

    Process.put(:synapsis_run_events_put_result, {:error, :boom})
    assert {:error, :boom} = Runs.mark_starting(run)
    Process.delete(:synapsis_run_events_put_result)

    stored = Runs.get(run.id)
    assert stored.status == "queued"
    assert {:reconcile, "failed", _} = RunReconciler.classify(stored, %{alive?: false})
  end

  test "start fact persisted then projection write fails does not claim running" do
    assert {:ok, run} = Runs.create(@attrs)

    # Event write succeeds; projection write fails after reduce+append ordering:
    # apply_event appends then persist — inject persist failure.
    Process.put(:synapsis_agent_runs_put_result, {:error, :proj_fail})
    assert {:error, :proj_fail} = Runs.mark_starting(run)
    Process.delete(:synapsis_agent_runs_put_result)

    stored = Runs.get(run.id)
    assert stored.status == "queued"
  end

  test "after start, before tool — reconcile without side effect is failed" do
    assert {:ok, run} = Runs.create(@attrs)
    assert {:ok, run} = Runs.mark_running(run)

    assert {:reconcile, "failed", _} = RunReconciler.classify(run, %{alive?: false})
  end

  test "after side-effect intent — reconcile is unknown_outcome" do
    assert {:ok, run} = Runs.create(@attrs)
    assert {:ok, run} = Runs.mark_running(run)
    assert {:ok, run} = Runs.mark_side_effect_intent(run)

    assert {:reconcile, "unknown_outcome", _} = RunReconciler.classify(run, %{alive?: false})
  end

  test "after tool result path can still complete" do
    assert {:ok, run} = Runs.create(@attrs)
    assert {:ok, run} = Runs.mark_running(run)
    assert {:ok, run} = Runs.mark_side_effect_intent(run)
    assert {:ok, done} = Runs.mark_completed(run, "tool finished")
    assert done.status == "completed"
    assert {:keep, _} = RunReconciler.classify(done, %{})
  end

  test "failure before terminal fact leaves running and classifies correctly" do
    assert {:ok, run} = Runs.create(@attrs)
    assert {:ok, run} = Runs.mark_running(run)

    Process.put(:synapsis_run_events_put_result, {:error, :terminal_fail})
    assert {:error, :terminal_fail} = Runs.mark_completed(run, "nope")
    Process.delete(:synapsis_run_events_put_result)

    stored = Runs.get(run.id)
    assert stored.status == "running"
    assert {:reconcile, "failed", _} = RunReconciler.classify(stored, %{})
  end

  test "deadline path reconciles to timed_out" do
    deadline = DateTime.add(DateTime.utc_now(), -10, :second)
    assert {:ok, run} = Runs.create(Map.put(@attrs, :deadline_at, deadline))
    assert {:ok, run} = Runs.mark_running(run)

    assert {:reconcile, "timed_out", _} =
             RunReconciler.classify(run, %{now: DateTime.utc_now(), alive?: false})
  end
end
