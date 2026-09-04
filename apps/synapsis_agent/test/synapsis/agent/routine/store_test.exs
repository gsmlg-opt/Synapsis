defmodule Synapsis.Agent.Routine.StoreTest do
  use Synapsis.Agent.DataCase, async: false

  alias Synapsis.Agent.Routine.{Occurrence, State}

  setup do
    Synapsis.DataCase.clear_coord("coord/routines/")
    Synapsis.DataCase.clear_coord("coord/routine_occurrences/")
    :ok
  end

  test "state persist round-trip and fail-closed" do
    assert {:ok, state} = State.put_next_run("routine-a", ~U[2026-09-04 12:00:00Z])
    assert state.next_run_at == ~U[2026-09-04 12:00:00Z]
    assert %{} = State.get("routine-a")

    Process.put(:synapsis_routine_state_put_result, {:error, :injected})
    assert {:error, :injected} = State.persist(State.new("routine-b"))
  after
    Process.delete(:synapsis_routine_state_put_result)
  end

  test "failure streak and backoff; success resets" do
    retry = %{max_attempts: 3, base_ms: 1_000, max_ms: 10_000}
    now = ~U[2026-09-04 12:00:00Z]

    assert {:ok, s1} =
             State.record_failure("r-fail", "boom", retry_policy: retry, now: now, run_id: "run1")

    assert s1.failure_streak == 1
    assert %DateTime{} = s1.backoff_until
    assert State.in_backoff?(s1, now)
    refute State.in_backoff?(s1, DateTime.add(s1.backoff_until, 1, :second))

    assert {:ok, s2} = State.record_success("r-fail", "run2")
    assert s2.failure_streak == 0
    assert s2.backoff_until == nil
  end

  test "occurrence create_if_absent is idempotent; claim then finish" do
    scheduled = ~U[2026-09-04 15:00:00Z]
    occ = Occurrence.build("r-occ", scheduled)

    assert {:ok, created} = Occurrence.create_if_absent(occ)
    assert created.status == "scheduled"
    assert {:ok, ^created} = Occurrence.create_if_absent(occ)

    assert {:ok, claimed} = Occurrence.claim("r-occ", occ.occurrence_key)
    assert claimed.status == "claimed"
    assert {:error, {:already_active, _}} = Occurrence.claim("r-occ", occ.occurrence_key)

    assert {:ok, running} = Occurrence.mark_started(claimed, "run-xyz")
    assert running.status == "running"
    assert running.run_id == "run-xyz"

    assert {:ok, done} = Occurrence.mark_finished(running, "completed", outcome: "completed")
    assert done.status == "completed"
  end

  test "mark_skipped records reason" do
    scheduled = ~U[2026-09-04 16:00:00Z]
    key = Synapsis.Agent.Routine.Schedule.occurrence_key("r-skip", scheduled)

    assert {:ok, skipped} =
             Occurrence.mark_skipped("r-skip", key, "no_overlap", scheduled_for: scheduled)

    assert skipped.status == "skipped"
    assert skipped.skip_reason == "no_overlap"
  end
end
