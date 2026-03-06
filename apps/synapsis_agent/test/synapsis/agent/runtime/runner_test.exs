defmodule Synapsis.Agent.Runtime.RunnerTest do
  use Synapsis.Agent.DataCase, async: false

  alias Synapsis.Agent.Runtime.{CheckpointStore, Graph, Node, Runner}

  defmodule PlannerNode do
    @behaviour Node

    @impl true
    def run(state, _ctx) do
      {:next, :planned, Map.update(state, :steps, [:planner], &(&1 ++ [:planner]))}
    end
  end

  defmodule ExecutorNode do
    @behaviour Node

    @impl true
    def run(state, _ctx) do
      {:next, :done, Map.update(state, :steps, [:executor], &(&1 ++ [:executor]))}
    end
  end

  defmodule FinishNode do
    @behaviour Node

    @impl true
    def run(state, _ctx) do
      {:end, Map.update(state, :steps, [:finish], &(&1 ++ [:finish]))}
    end
  end

  defmodule ApprovalNode do
    @behaviour Node

    @impl true
    def run(state, ctx) do
      if Map.get(ctx, :approved, false) do
        {:next, :approved, Map.put(state, :approved, true)}
      else
        {:wait, state}
      end
    end
  end

  defmodule MissingEdgeNode do
    @behaviour Node

    @impl true
    def run(state, _ctx), do: {:next, :missing, state}
  end

  test "executes a linear graph to completion" do
    graph = %Graph{
      nodes: %{planner: PlannerNode, executor: ExecutorNode, finish: FinishNode},
      edges: %{planner: %{planned: :executor}, executor: %{done: :finish}, finish: :end},
      start: :planner
    }

    assert {:ok, snapshot} = Runner.run(graph, %{steps: []})
    assert snapshot.status == :completed
    assert snapshot.node == :end
    assert snapshot.state.steps == [:planner, :executor, :finish]
  end

  test "pauses and resumes waiting runs" do
    graph = %Graph{
      nodes: %{approval: ApprovalNode, finish: FinishNode},
      edges: %{approval: %{approved: :finish}, finish: :end},
      start: :approval
    }

    assert {:ok, pid} = Runner.start_link(graph: graph, state: %{}, ctx: %{})

    waiting = Runner.await(pid)
    assert waiting.status == :waiting
    assert waiting.node == :approval

    assert :ok = Runner.resume(pid, %{approved: true})
    completed = Runner.await(pid)

    assert completed.status == :completed
    assert completed.node == :end
    assert completed.state.approved
  end

  test "fails when transition selector cannot be resolved" do
    graph = %Graph{
      nodes: %{planner: MissingEdgeNode},
      edges: %{planner: %{ok: :end}},
      start: :planner
    }

    assert {:error, {:invalid_transition, {:unknown_edge_selector, :planner, :missing}}, snapshot} =
             Runner.run(graph, %{})

    assert snapshot.status == :failed
    assert snapshot.node == :planner
  end

  test "emits lifecycle events through handler callback" do
    parent = self()

    event_handler = fn event ->
      send(parent, {:runtime_event, event.type, event.node})
    end

    graph = %Graph{
      nodes: %{finish: FinishNode},
      edges: %{finish: :end},
      start: :finish
    }

    assert {:ok, _snapshot} = Runner.run(graph, %{}, event_handler: event_handler)

    assert_received {:runtime_event, :agent_started, :finish}
    assert_received {:runtime_event, :node_started, :finish}
    assert_received {:runtime_event, :node_finished, :finish}
    assert_received {:runtime_event, :agent_finished, :end}
  end

  test "persists waiting checkpoint and supports resume by run_id after restart" do
    run_id = "run-checkpoint-" <> Integer.to_string(System.unique_integer([:positive]))

    graph = %Graph{
      nodes: %{approval: ApprovalNode, finish: FinishNode},
      edges: %{approval: %{approved: :finish}, finish: :end},
      start: :approval
    }

    assert {:ok, pid} = Runner.start_link(graph: graph, state: %{}, ctx: %{}, run_id: run_id)
    waiting = Runner.await(pid)

    assert waiting.status == :waiting
    assert waiting.node == :approval

    assert {:ok, checkpoint} = CheckpointStore.get(run_id)
    assert checkpoint.status == :waiting
    assert checkpoint.node == :approval

    assert :ok = GenServer.stop(pid, :normal)
    assert eventually(fn -> Runner.whereis(run_id) == nil end)

    assert :ok = Runner.resume(run_id, %{approved: true})

    assert eventually(fn ->
             case Runner.await(run_id, 50) do
               %{status: :completed, node: :end, state: %{approved: true}} -> true
               _ -> false
             end
           end)

    assert {:ok, completed_checkpoint} = CheckpointStore.get(run_id)
    assert completed_checkpoint.status == :completed
    assert completed_checkpoint.node == :end
    assert completed_checkpoint.state.approved
  end

  test "reads snapshot by run_id from checkpoint when runner is offline" do
    run_id = "run-offline-" <> Integer.to_string(System.unique_integer([:positive]))

    graph = %Graph{
      nodes: %{approval: ApprovalNode, finish: FinishNode},
      edges: %{approval: %{approved: :finish}, finish: :end},
      start: :approval
    }

    assert {:ok, pid} = Runner.start_link(graph: graph, state: %{}, ctx: %{}, run_id: run_id)
    assert %{status: :waiting} = Runner.await(pid)
    assert :ok = GenServer.stop(pid, :normal)
    assert eventually(fn -> Runner.whereis(run_id) == nil end)

    assert %{run_id: ^run_id, status: :waiting, node: :approval} = Runner.snapshot(run_id)
    assert %{run_id: ^run_id, status: :waiting, node: :approval} = Runner.await(run_id)
  end

  defp eventually(fun, retries \\ 30)

  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, retries) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, retries - 1)
    end
  end
end
