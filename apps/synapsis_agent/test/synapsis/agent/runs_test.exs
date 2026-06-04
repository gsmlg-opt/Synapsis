defmodule Synapsis.Agent.RunsTest do
  use Synapsis.Agent.DataCase, async: false

  alias Synapsis.Agent.Runs

  setup do
    # ADR-006 C4: runs live in the global Concord coord store; isolate per test.
    Synapsis.DataCase.clear_coord("coord/agent_runs/")
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

    test "recovers stale running and waiting runs" do
      stale_time = DateTime.add(DateTime.utc_now(), -7200, :second)

      assert {:ok, running} = Runs.create(%{@valid_attrs | prompt: "Stale running."})
      assert {:ok, running} = Runs.mark_running(running, %{started_at: stale_time})

      assert {:ok, waiting} = Runs.create(%{@valid_attrs | prompt: "Stale waiting."})
      assert {:ok, waiting} = Runs.mark_waiting_approval(waiting, %{started_at: stale_time})

      assert {2, nil} = Runs.recover_stale_running_runs(older_than: DateTime.utc_now())

      assert %{status: "failed", error: "daemon restarted before completion"} =
               Runs.get(running.id)

      assert %{status: "failed", error: "daemon restarted before completion"} =
               Runs.get(waiting.id)
    end
  end
end
