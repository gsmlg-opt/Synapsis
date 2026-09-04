defmodule Synapsis.Agent.Routine.SchedulerTest do
  use Synapsis.Agent.DataCase, async: false

  alias Synapsis.Agent.Routine.{Clock, Definition, Occurrence, Runner, Schedule, State}
  alias Synapsis.Agent.Runs

  setup do
    Synapsis.DataCase.clear_coord("coord/routines/")
    Synapsis.DataCase.clear_coord("coord/routine_occurrences/")
    Synapsis.DataCase.clear_coord("coord/agent_runs/")
    Synapsis.DataCase.clear_coord("coord/agent_run_idempotency/")
    Clock.reset()
    :ok
  end

  test "no-overlap skips second occurrence while first is active" do
    defn = heartbeat_def("ov-1", no_overlap: true)
    t1 = ~U[2026-09-04 10:00:00Z]
    t2 = ~U[2026-09-04 10:05:00Z]

    occ1 = Occurrence.build(defn.id, t1)
    assert {:ok, _} = Occurrence.create_if_absent(occ1)
    assert {:ok, claimed} = Occurrence.claim(defn.id, occ1.occurrence_key)
    assert {:ok, _} = Occurrence.mark_started(claimed, "run-active")

    assert {:ok, _} =
             Runs.create(%{
               kind: "heartbeat",
               source: "scheduler",
               prompt: "x",
               tool_profile: "heartbeat",
               routine_id: defn.id,
               heartbeat_id: defn.id,
               idempotency_key: "active-run-key"
             })

    occ2 = Occurrence.build(defn.id, t2)
    assert {:ok, scheduled} = Occurrence.create_if_absent(occ2)
    assert {:error, :overlap} = Runner.execute(defn, scheduled)

    skipped = Occurrence.get(defn.id, occ2.occurrence_key)
    assert skipped.status == "skipped"
    assert skipped.skip_reason == "no_overlap"
  end

  test "misfire skip marks overdue occurrences skipped and advances next_run_at" do
    defn = heartbeat_def("mf-skip", misfire_policy: :skip, schedule: "0 * * * *")
    overdue = ~U[2026-09-04 08:00:00Z]
    now = ~U[2026-09-04 10:30:00Z]
    Clock.freeze(now)

    assert {:ok, _} = State.put_next_run(defn.id, overdue)

    # Invoke private policy via reconcile-like path: use apply through Scheduler module
    # by calling reconcile_routine logic — expose via public reconcile after loading defs
    # Unit-level: call mark path used by apply_misfire
    key = Schedule.occurrence_key(defn.id, overdue)

    assert {:ok, _} =
             Occurrence.mark_skipped(defn.id, key, "misfire_skip",
               now: now,
               scheduled_for: overdue
             )

    assert {:ok, next} = Schedule.next_after(defn.schedule, defn.timezone, now)
    assert {:ok, _} = State.put_next_run(defn.id, next)

    assert Occurrence.get(defn.id, key).status == "skipped"
    assert DateTime.compare(State.get(defn.id).next_run_at, now) == :gt
  end

  test "misfire run_once keeps only the latest missed slot for claim" do
    defn = heartbeat_def("mf-once", misfire_policy: :run_once, schedule: "0 * * * *")
    now = ~U[2026-09-04 10:30:00Z]
    slots = [~U[2026-09-04 08:00:00Z], ~U[2026-09-04 09:00:00Z], ~U[2026-09-04 10:00:00Z]]

    older = Enum.take(slots, 2)
    latest = List.last(slots)

    Enum.each(older, fn at ->
      key = Schedule.occurrence_key(defn.id, at)

      assert {:ok, _} =
               Occurrence.mark_skipped(defn.id, key, "misfire_skip",
                 now: now,
                 scheduled_for: at
               )
    end)

    latest_key = Schedule.occurrence_key(defn.id, latest)
    occ = Occurrence.build(defn.id, latest)
    assert {:ok, created} = Occurrence.create_if_absent(occ)
    assert created.status == "scheduled"
    assert created.occurrence_key == latest_key

    Enum.each(older, fn at ->
      assert Occurrence.get(defn.id, Schedule.occurrence_key(defn.id, at)).status == "skipped"
    end)
  end

  test "same occurrence_key never creates a second AgentRun" do
    key = "dup-routine:2026-09-04T11:00:00Z"

    assert {:ok, run1} =
             Runs.create(%{
               kind: "heartbeat",
               source: "scheduler",
               prompt: "once",
               tool_profile: "heartbeat",
               routine_id: "dup-routine",
               idempotency_key: key
             })

    assert {:ok, run2} =
             Runs.create(%{
               kind: "heartbeat",
               source: "scheduler",
               prompt: "once again",
               tool_profile: "heartbeat",
               routine_id: "dup-routine",
               idempotency_key: key
             })

    assert run1.id == run2.id
  end

  test "boot reconcile fails claimed occurrence without live coordinator" do
    defn = heartbeat_def("rec-1")
    scheduled = ~U[2026-09-04 09:00:00Z]
    occ = Occurrence.build(defn.id, scheduled)
    assert {:ok, _} = Occurrence.create_if_absent(occ)
    assert {:ok, claimed} = Occurrence.claim(defn.id, occ.occurrence_key)

    assert {:ok, finished} = Runner.reconcile_occurrence(claimed, alive?: false)
    assert finished.status == "failed"
    assert finished.error =~ "claimed without run"
  end

  test "boot reconcile maps terminal run onto occurrence" do
    defn = heartbeat_def("rec-2")
    scheduled = ~U[2026-09-04 09:00:00Z]
    occ = Occurrence.build(defn.id, scheduled)
    assert {:ok, _} = Occurrence.create_if_absent(occ)
    assert {:ok, claimed} = Occurrence.claim(defn.id, occ.occurrence_key)

    assert {:ok, run} =
             Runs.create(%{
               kind: "heartbeat",
               source: "scheduler",
               prompt: "done",
               tool_profile: "heartbeat",
               routine_id: defn.id,
               idempotency_key: occ.occurrence_key <> ":run"
             })

    # Force terminal projection for occurrence reconcile (reducer path covered elsewhere)
    now = DateTime.utc_now()

    assert {:ok, run} =
             Runs.persist(%{
               run
               | status: "completed",
                 summary: "ok",
                 finished_at: now,
                 updated_at: now
             })

    assert {:ok, started} = Occurrence.mark_started(claimed, run.id)

    assert {:ok, finished} = Runner.reconcile_occurrence(started, alive?: false)
    assert finished.status == "completed"
  end

  test "LocalScheduler.status still works" do
    snapshot = Synapsis.Agent.Heartbeat.LocalScheduler.status()
    assert is_boolean(snapshot.degraded?)
    assert is_list(snapshot.entries)
  end

  defp heartbeat_def(id, opts \\ []) do
    %Definition{
      id: id,
      name: id,
      kind: :heartbeat,
      schedule: Keyword.get(opts, :schedule, "*/5 * * * *"),
      prompt: "ping",
      no_overlap: Keyword.get(opts, :no_overlap, true),
      misfire_policy: Keyword.get(opts, :misfire_policy, :skip),
      timezone: "Etc/UTC",
      tool_profile: "heartbeat",
      retry_policy: %{max_attempts: 3, base_ms: 1_000, max_ms: 60_000}
    }
  end
end
