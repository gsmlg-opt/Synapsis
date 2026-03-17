defmodule Synapsis.Agent.Nodes.NodeTest do
  use Synapsis.Agent.DataCase, async: true

  alias Synapsis.Agent.Nodes
  alias Synapsis.Agent.Graphs.CodingLoop

  describe "ReceiveMessage" do
    test "pauses when no user_input" do
      state = CodingLoop.initial_state(%{session_id: "s1"})
      assert {:wait, ^state} = Nodes.ReceiveMessage.run(state, %{})
    end

    test "proceeds when user_input provided" do
      state = CodingLoop.initial_state(%{session_id: "s1"})
      state = Map.put(state, :user_input, "hello")
      assert {:next, :default, new_state} = Nodes.ReceiveMessage.run(state, %{})
      assert new_state.user_input == "hello"
    end
  end

  describe "ProcessResponse" do
    test "routes to :no_tools when no tool_uses" do
      state = %{
        session_id: Ecto.UUID.generate(),
        pending_text: "",
        pending_tool_use: nil,
        pending_tool_input: "",
        pending_reasoning: "",
        tool_uses: []
      }

      assert {:next, :no_tools, _state} = Nodes.ProcessResponse.run(state, %{})
    end

    test "routes to :has_tools when tool_uses present" do
      tool_use = %Synapsis.Part.ToolUse{
        tool: "file_read",
        tool_use_id: "tu_1",
        input: %{"path" => "/foo"},
        status: :pending
      }

      # Empty pending_text so flush is a no-op (no DB insert), but tool_uses present
      state = %{
        session_id: Ecto.UUID.generate(),
        pending_text: "",
        pending_tool_use: nil,
        pending_tool_input: "",
        pending_reasoning: "",
        tool_uses: [tool_use]
      }

      assert {:next, :has_tools, _state} = Nodes.ProcessResponse.run(state, %{})
    end
  end

  describe "LLMStream" do
    test "proceeds when stream_completed" do
      state =
        CodingLoop.initial_state(%{session_id: "s1"})
        |> Map.put(:stream_completed, true)
        |> Map.put(:request, %{})

      assert {:next, :default, new_state} = Nodes.LLMStream.run(state, %{})
      refute Map.has_key?(new_state, :stream_completed)
    end
  end

  describe "Orchestrate" do
    test "increments iteration_count" do
      state =
        CodingLoop.initial_state(%{session_id: Ecto.UUID.generate()})
        |> Map.put(:tool_uses, [])

      assert {:next, selector, new_state} = Nodes.Orchestrate.run(state, %{})
      assert new_state.iteration_count == 1
      assert selector in [:continue, :pause, :escalate, :terminate]
    end
  end

  describe "ApprovalGate" do
    test "pauses when no approval_decisions" do
      state =
        CodingLoop.initial_state(%{session_id: Ecto.UUID.generate()})
        |> Map.put(:classified_tools, [])

      assert {:wait, _state} = Nodes.ApprovalGate.run(state, %{})
    end

    test "routes to :approved when decisions provided" do
      tool_use = %Synapsis.Part.ToolUse{
        tool: "file_write",
        tool_use_id: "tu_1",
        input: %{},
        status: :pending
      }

      state =
        CodingLoop.initial_state(%{session_id: Ecto.UUID.generate()})
        |> Map.put(:classified_tools, [{:requires_approval, tool_use}])
        |> Map.put(:approval_decisions, %{"tu_1" => :approved})

      assert {:next, :approved, _state} = Nodes.ApprovalGate.run(state, %{})
    end

    test "routes to :denied when all denied" do
      tool_use = %Synapsis.Part.ToolUse{
        tool: "file_write",
        tool_use_id: "tu_1",
        input: %{},
        status: :pending
      }

      state =
        CodingLoop.initial_state(%{session_id: Ecto.UUID.generate()})
        |> Map.put(:classified_tools, [{:requires_approval, tool_use}])
        |> Map.put(:approval_decisions, %{"tu_1" => :denied})

      assert {:next, :denied, _state} = Nodes.ApprovalGate.run(state, %{})
    end
  end

  describe "Escalate" do
    test "proceeds when auditor_completed" do
      state =
        CodingLoop.initial_state(%{session_id: Ecto.UUID.generate()})
        |> Map.put(:auditor_completed, true)

      assert {:next, :default, new_state} = Nodes.Escalate.run(state, %{})
      refute Map.has_key?(new_state, :auditor_completed)
    end
  end

  describe "Complete" do
    test "returns :end" do
      state = CodingLoop.initial_state(%{session_id: Ecto.UUID.generate()})
      assert {:end, ^state} = Nodes.Complete.run(state, %{})
    end
  end
end
