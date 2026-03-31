defmodule Synapsis.Agent.Nodes.ApprovalGateTest do
  use Synapsis.Agent.DataCase, async: true

  alias Synapsis.Agent.Nodes.ApprovalGate

  describe "run/2 — resumed path" do
    test "routes to :approved when user approves tools" do
      tool_use = %Synapsis.Part.ToolUse{
        tool: "bash_exec",
        tool_use_id: "tu_1",
        input: %{"command" => "mix test"},
        status: :pending
      }

      state = %{
        session_id: Ecto.UUID.generate(),
        awaiting_approval: true,
        classified_tools: [{:needs_approval, tool_use}],
        agent_config: %{project_id: nil}
      }

      ctx = %{approval_decisions: %{"tu_1" => :approved}}

      assert {:next, :approved, new_state} = ApprovalGate.run(state, ctx)
      assert [{:approved, _}] = new_state.classified_tools
      refute Map.has_key?(new_state, :awaiting_approval)
    end

    test "routes to :denied when user denies all tools" do
      tool_use = %Synapsis.Part.ToolUse{
        tool: "bash_exec",
        tool_use_id: "tu_1",
        input: %{"command" => "rm -rf /"},
        status: :pending
      }

      state = %{
        session_id: Ecto.UUID.generate(),
        awaiting_approval: true,
        classified_tools: [{:needs_approval, tool_use}],
        agent_config: %{project_id: nil}
      }

      ctx = %{approval_decisions: %{"tu_1" => :denied}}

      assert {:next, :denied, new_state} = ApprovalGate.run(state, ctx)
      assert [{:denied, _}] = new_state.classified_tools
    end
  end
end
