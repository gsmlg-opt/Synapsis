defmodule Synapsis.Agent.RunsTest do
  use Synapsis.Agent.DataCase, async: false

  alias Synapsis.Agent.Runs
  alias Synapsis.Agent.RunEvents

  setup do
    Synapsis.DataCase.clear_coord("coord/agent_runs/")
    Synapsis.DataCase.clear_coord("coord/agent_run_events/")
    Synapsis.DataCase.clear_coord("coord/agent_run_event_ids/")
    Synapsis.DataCase.clear_coord("coord/agent_run_idempotency/")
    Process.delete(:synapsis_agent_runs_put_result)
    Process.delete(:synapsis_run_events_put_result)
    :ok
  end

  @valid_attrs %{
    kind: "manual",
    source: "web",
    assistant_name: "build",
    prompt: "Check project health.",
    tool_profile: "read_only",
    metadata: %{"request_id" => "run-test"}
  }

  describe "lifecycle" do
    test "creates and moves runs through terminal states" do
      assert {:ok, queued} = Runs.create(@valid_attrs)
      assert queued.status == "queued"
      assert queued.kind == "manual"
      assert queued.source == "web"
      assert queued.metadata == %{"request_id" => "run-test"}
      assert queued.last_event_sequence >= 1
      assert queued.revision >= 1

      assert {:ok, running} = Runs.mark_running(queued)
      assert running.status == "running"
      assert %DateTime{} = running.started_at

      assert {:ok, completed} = Runs.mark_completed(running, "No issues found.")
      assert completed.status == "completed"
      assert completed.summary == "No issues found."
      assert %DateTime{} = completed.finished_at

      assert {:ok, failed} =
               Runs.create(%{@valid_attrs | prompt: "Check failure path."})
               |> then(fn {:ok, run} -> Runs.mark_failed(run, "provider unavailable") end)

      assert failed.status == "failed"
      assert failed.error == "provider unavailable"
      assert %DateTime{} = failed.finished_at
    end

    test "lists recent runs newest first" do
      assert {:ok, older} = Runs.create(%{@valid_attrs | prompt: "First run."})
      assert {:ok, newer} = Runs.create(%{@valid_attrs | prompt: "Second run."})

      assert [first, second] = Runs.list_recent(limit: 2)
      assert first.id == newer.id
      assert second.id == older.id
    end

    test "recovers stale runs without side effects as failed" do
      stale_time = DateTime.add(DateTime.utc_now(), -7200, :second)

      assert {:ok, running} = Runs.create(%{@valid_attrs | prompt: "Stale running."})
      assert {:ok, running} = Runs.mark_running(running, %{started_at: stale_time})

      assert {:ok, waiting} = Runs.create(%{@valid_attrs | prompt: "Stale waiting."})
      assert {:ok, waiting} = Runs.mark_waiting_approval(waiting, %{started_at: stale_time})

      assert {2, nil} = Runs.recover_stale_running_runs(older_than: DateTime.utc_now())

      assert %{status: "failed", failure_class: "restart"} = Runs.get(running.id)
      assert %{status: "failed"} = Runs.get(waiting.id)
    end

    test "recovers stale runs with side-effect intent as unknown_outcome" do
      stale_time = DateTime.add(DateTime.utc_now(), -7200, :second)

      assert {:ok, run} = Runs.create(%{@valid_attrs | prompt: "Uncertain."})
      assert {:ok, run} = Runs.mark_running(run, %{started_at: stale_time})
      assert {:ok, run} = Runs.mark_side_effect_intent(run)
      assert run.recovery_state["side_effect_intent"] == true

      assert {1, nil} = Runs.recover_stale_running_runs(older_than: DateTime.utc_now())
      assert %{status: "unknown_outcome"} = Runs.get(run.id)
    end

    test "idempotency_key returns the existing run" do
      attrs = Map.put(@valid_attrs, :idempotency_key, "idem-1")
      assert {:ok, first} = Runs.create(attrs)
      assert {:ok, second} = Runs.create(attrs)
      assert first.id == second.id
    end

    test "persist failure does not report success" do
      assert {:ok, run} = Runs.create(@valid_attrs)
      before = Runs.get(run.id)

      Process.put(:synapsis_agent_runs_put_result, {:error, :injected_put_failure})

      assert {:error, :injected_put_failure} = Runs.mark_running(run)
      assert Runs.get(run.id).status == before.status
    after
      Process.delete(:synapsis_agent_runs_put_result)
    end

    test "critical event append failure blocks transition" do
      assert {:ok, run} = Runs.create(@valid_attrs)

      Process.put(:synapsis_run_events_put_result, {:error, :injected_event_failure})

      assert {:error, :injected_event_failure} = Runs.mark_starting(run)
      assert Runs.get(run.id).status == "queued"
    after
      Process.delete(:synapsis_run_events_put_result)
    end

    test "duplicate lifecycle event_id is idempotent" do
      assert {:ok, run} = Runs.create(@valid_attrs)
      event_id = Ecto.UUID.generate()

      assert {:ok, started} = Runs.mark_starting(run, %{event_id: event_id})
      assert {:ok, again} = Runs.mark_starting(started, %{event_id: event_id})
      assert again.status == "starting"
      assert again.revision == started.revision
    end

    test "structured tool events store queryable fields" do
      assert {:ok, run} = Runs.create(@valid_attrs)

      assert :ok =
               RunEvents.append_tool_event(run, %{
                 tool_name: "bash",
                 class: "execute",
                 status: "denied",
                 duration_ms: 12,
                 denial_or_failure_reason: "policy",
                 correlation_id: "c1",
                 huge: String.duplicate("x", 10_000)
               })
    end
  end
end
