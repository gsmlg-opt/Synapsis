defmodule Synapsis.Agent.Runtime.RunnerTest do
  # Runner is now a pure sync wrapper over Engine — no DB, no process, runs async.
  use ExUnit.Case, async: true

  alias Synapsis.Agent.Runtime.{Engine, Graph, Node, Runner}

  defmodule PlannerNode do
    @behaviour Node
    @impl true
    def run(state, _ctx),
      do: {:next, :planned, Map.update(state, :steps, [:planner], &(&1 ++ [:planner]))}
  end

  defmodule ExecutorNode do
    @behaviour Node
    @impl true
    def run(state, _ctx),
      do: {:next, :done, Map.update(state, :steps, [:executor], &(&1 ++ [:executor]))}
  end

  defmodule FinishNode do
    @behaviour Node
    @impl true
    def run(state, _ctx),
      do: {:end, Map.update(state, :steps, [:finish], &(&1 ++ [:finish]))}
  end

  defmodule WaitNode do
    @behaviour Node
    @impl true
    def run(state, ctx) do
      if Map.get(ctx, :approved, false),
        do: {:next, :approved, Map.put(state, :approved, true)},
        else: {:wait, state}
    end
  end

  defmodule MissingEdgeNode do
    @behaviour Node
    @impl true
    def run(state, _ctx), do: {:next, :missing, state}
  end

  defmodule CrashNode do
    @behaviour Node
    @impl true
    def run(_state, _ctx), do: raise("boom")
  end

  # --- Runner.run/3 tests ---

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

  test "parks at first wait node" do
    graph = %Graph{
      nodes: %{approval: WaitNode, finish: FinishNode},
      edges: %{approval: %{approved: :finish}, finish: :end},
      start: :approval
    }

    assert {:ok, snapshot} = Runner.run(graph, %{}, ctx: %{})
    assert snapshot.status == :waiting
    assert snapshot.node == :approval
  end

  test "reaches completion when ctx satisfies wait condition" do
    graph = %Graph{
      nodes: %{approval: WaitNode, finish: FinishNode},
      edges: %{approval: %{approved: :finish}, finish: :end},
      start: :approval
    }

    assert {:ok, snapshot} = Runner.run(graph, %{}, ctx: %{approved: true})
    assert snapshot.status == :completed
    assert snapshot.node == :end
    assert snapshot.state.approved
  end

  test "returns error when transition selector cannot be resolved" do
    graph = %Graph{
      nodes: %{planner: MissingEdgeNode},
      edges: %{planner: %{ok: :end}},
      start: :planner
    }

    assert {:error, {:invalid_transition, :planner, :missing, _}, snapshot} =
             Runner.run(graph, %{})

    assert snapshot.status == :failed
  end

  test "returns error when node crashes" do
    graph = %Graph{
      nodes: %{boom: CrashNode},
      edges: %{boom: :end},
      start: :boom
    }

    assert {:error, {:node_crash, CrashNode, %RuntimeError{message: "boom"}, _}, snapshot} =
             Runner.run(graph, %{})

    assert snapshot.status == :failed
  end

  # --- Engine.run_until_wait/4 tests ---

  test "Engine steps through the full graph" do
    {:ok, graph} =
      Graph.new(%{
        nodes: %{planner: PlannerNode, finish: FinishNode},
        edges: %{planner: %{planned: :finish}, finish: :end},
        start: :planner
      })

    assert {:done, %{steps: [:planner, :finish]}} =
             Engine.run_until_wait(graph, :planner, %{steps: []}, %{})
  end

  test "Engine parks at wait node and preserves state" do
    {:ok, graph} =
      Graph.new(%{
        nodes: %{approval: WaitNode, finish: FinishNode},
        edges: %{approval: %{approved: :finish}, finish: :end},
        start: :approval
      })

    assert {:waiting, :approval, parked_state} =
             Engine.run_until_wait(graph, :approval, %{}, %{})

    # Re-step from the parked state with approval in ctx — should finish.
    assert {:done, %{approved: true}} =
             Engine.run_until_wait(graph, :approval, parked_state, %{approved: true})
  end

  test "Engine.step resolves conditional edges" do
    {:ok, graph} =
      Graph.new(%{
        nodes: %{planner: PlannerNode, executor: ExecutorNode, finish: FinishNode},
        edges: %{planner: %{planned: :executor}, executor: %{done: :finish}, finish: :end},
        start: :planner
      })

    assert {:next, :executor, %{steps: [:planner]}} =
             Engine.step(graph, :planner, %{steps: []}, %{})
  end
end
