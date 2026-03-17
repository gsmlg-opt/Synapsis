defmodule Synapsis.Agent.Graphs.CodingLoopTest do
  use ExUnit.Case, async: true

  alias Synapsis.Agent.Graphs.CodingLoop
  alias Synapsis.Agent.Runtime.Graph

  describe "build/0" do
    test "creates valid graph" do
      assert {:ok, %Graph{}} = CodingLoop.build()
    end

    test "all nodes resolve" do
      {:ok, graph} = CodingLoop.build()

      for {name, module} <- graph.nodes do
        assert is_atom(name)
        assert is_atom(module)

        assert function_exported?(module, :run, 2),
               "Node #{name} (#{module}) must implement run/2"
      end
    end

    test "all edge targets exist" do
      {:ok, graph} = CodingLoop.build()

      for {_from, target} <- graph.edges do
        case target do
          :end ->
            :ok

          atom when is_atom(atom) ->
            assert Map.has_key?(graph.nodes, atom),
                   "Edge target :#{atom} not in nodes"

          map when is_map(map) ->
            for {_selector, dest} <- map do
              if dest != :end do
                assert Map.has_key?(graph.nodes, dest),
                       "Edge target :#{dest} not in nodes"
              end
            end
        end
      end
    end

    test "start node is :receive" do
      {:ok, graph} = CodingLoop.build()
      assert graph.start == :receive
    end

    test "has all 11 nodes" do
      {:ok, graph} = CodingLoop.build()
      assert map_size(graph.nodes) == 11

      expected = ~w(receive compact_context build_prompt llm_stream process_response tool_dispatch
                    approval_gate tool_execute orchestrate escalate complete)a

      for name <- expected do
        assert Map.has_key?(graph.nodes, name), "Missing node :#{name}"
      end
    end
  end

  describe "initial_state/1" do
    test "returns map with required fields" do
      state =
        CodingLoop.initial_state(%{
          session_id: "test-123",
          provider_config: %{api_key: "key"},
          agent_config: %{name: "build"},
          worktree_path: "/tmp/wt"
        })

      assert state.session_id == "test-123"
      assert state.pending_text == ""
      assert state.tool_uses == []
      assert state.iteration_count == 0
      assert state.worktree_path == "/tmp/wt"
      assert %MapSet{} = state.tool_call_hashes
    end
  end
end
