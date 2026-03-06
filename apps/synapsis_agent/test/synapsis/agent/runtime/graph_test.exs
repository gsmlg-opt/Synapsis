defmodule Synapsis.Agent.Runtime.GraphTest do
  use ExUnit.Case, async: true

  alias Synapsis.Agent.Runtime.{Graph, Node}

  defmodule PlannerNode do
    @behaviour Node
    def run(state, _ctx), do: {:next, :planned, state}
  end

  defmodule ExecutorNode do
    @behaviour Node
    def run(state, _ctx), do: {:end, state}
  end

  test "valid graph validates and resolves conditional edges" do
    graph = %{
      nodes: %{planner: PlannerNode, executor: ExecutorNode},
      edges: %{planner: %{planned: :executor}, executor: :end},
      start: :planner
    }

    assert {:ok, runtime_graph} = Graph.new(graph)
    assert {:ok, :executor} = Graph.resolve_next(runtime_graph, :planner, :planned)
    assert {:ok, :end} = Graph.resolve_next(runtime_graph, :executor, :any)
  end

  test "rejects unknown start node" do
    graph = %{
      nodes: %{planner: PlannerNode},
      edges: %{},
      start: :missing
    }

    assert {:error, {:unknown_start_node, :missing}} = Graph.new(graph)
  end

  test "rejects unknown edge destination" do
    graph = %{
      nodes: %{planner: PlannerNode},
      edges: %{planner: :missing},
      start: :planner
    }

    assert {:error, {:unknown_edge_destination, :missing}} = Graph.new(graph)
  end
end
