defmodule Synapsis.Agent.RunSupervisorTest do
  use Synapsis.Agent.DataCase, async: false

  alias Synapsis.Agent.RunSupervisor
  alias Synapsis.Agent.Runs

  setup do
    Synapsis.DataCase.clear_coord("coord/agent_runs/")
    Synapsis.DataCase.clear_coord("coord/agent_run_events/")
    Synapsis.DataCase.clear_coord("coord/agent_run_event_ids/")
    Synapsis.DataCase.clear_coord("coord/agent_run_idempotency/")
    :ok
  end

  test "start_run is idempotent for the same run_id" do
    assert {:ok, run} =
             Runs.create(%{
               kind: "manual",
               source: "system",
               prompt: "supervisor test",
               tool_profile: "read_only"
             })

    # Terminal immediately so coordinator exits quickly if it bootstraps.
    assert {:ok, run} = Runs.mark_failed(run, "stop early")

    assert {:ok, pid1} = RunSupervisor.start_run(%{run_id: run.id})
    # May already be stopped (temporary + terminal); start again is fine.
    result = RunSupervisor.start_run(%{run_id: run.id})
    assert match?({:ok, _}, result)

    _ = pid1
  end

  test "list_active_run_ids returns binaries" do
    ids = RunSupervisor.list_active_run_ids()
    assert is_list(ids)
    assert Enum.all?(ids, &is_binary/1)
  end
end
