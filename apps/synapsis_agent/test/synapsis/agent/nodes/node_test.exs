defmodule Synapsis.Agent.Nodes.NodeTest do
  use Synapsis.Agent.DataCase, async: true

  alias Synapsis.Agent.Nodes
  alias Synapsis.Agent.Graphs.CodingLoop

  describe "ReceiveMessage" do
    test "pauses on first call (no awaiting_input flag)" do
      state = CodingLoop.initial_state(%{session_id: "s1"})
      assert {:wait, new_state} = Nodes.ReceiveMessage.run(state, %{})
      assert new_state[:awaiting_input] == true
    end

    test "proceeds on resume when ctx has user_input and state has awaiting_input" do
      state =
        CodingLoop.initial_state(%{session_id: "s1"})
        |> Map.put(:awaiting_input, true)

      ctx = %{user_input: "hello", image_parts: []}
      assert {:next, :default, new_state} = Nodes.ReceiveMessage.run(state, ctx)
      assert new_state.user_input == "hello"
      refute Map.has_key?(new_state, :awaiting_input)
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
    test "pauses on first call and sets awaiting_stream" do
      state =
        CodingLoop.initial_state(%{session_id: "s1"})
        |> Map.put(:request, %{})

      assert {:wait, new_state} = Nodes.LLMStream.run(state, %{})
      assert new_state[:awaiting_stream] == true
    end

    test "proceeds on resume when ctx has stream_acc" do
      state =
        CodingLoop.initial_state(%{session_id: "s1"})
        |> Map.put(:awaiting_stream, true)
        |> Map.put(:request, %{})

      acc = %{
        pending_text: "hello world",
        pending_tool_use: nil,
        pending_tool_input: "",
        pending_reasoning: "",
        tool_uses: []
      }

      ctx = %{stream_acc: acc}
      assert {:next, :default, new_state} = Nodes.LLMStream.run(state, ctx)
      assert new_state.pending_text == "hello world"
      refute Map.has_key?(new_state, :awaiting_stream)
    end

    test "routes to :error when ctx has stream_error" do
      state =
        CodingLoop.initial_state(%{session_id: "s1"})
        |> Map.put(:awaiting_stream, true)

      ctx = %{stream_error: "connection_failed"}
      assert {:next, :error, new_state} = Nodes.LLMStream.run(state, ctx)
      assert new_state[:stream_error] == "connection_failed"
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
    test "pauses on first call and sets awaiting_approval" do
      state =
        CodingLoop.initial_state(%{session_id: Ecto.UUID.generate()})
        |> Map.put(:classified_tools, [])

      assert {:wait, new_state} = Nodes.ApprovalGate.run(state, %{})
      assert new_state[:awaiting_approval] == true
    end

    test "routes to :approved on resume with approval decisions" do
      tool_use = %Synapsis.Part.ToolUse{
        tool: "file_write",
        tool_use_id: "tu_1",
        input: %{},
        status: :pending
      }

      state =
        CodingLoop.initial_state(%{session_id: Ecto.UUID.generate()})
        |> Map.put(:classified_tools, [{:requires_approval, tool_use}])
        |> Map.put(:awaiting_approval, true)

      ctx = %{approval_decisions: %{"tu_1" => :approved}}
      assert {:next, :approved, _state} = Nodes.ApprovalGate.run(state, ctx)
    end

    test "routes to :denied when all denied on resume" do
      tool_use = %Synapsis.Part.ToolUse{
        tool: "file_write",
        tool_use_id: "tu_1",
        input: %{},
        status: :pending
      }

      state =
        CodingLoop.initial_state(%{session_id: Ecto.UUID.generate()})
        |> Map.put(:classified_tools, [{:requires_approval, tool_use}])
        |> Map.put(:awaiting_approval, true)

      ctx = %{approval_decisions: %{"tu_1" => :denied}}
      assert {:next, :denied, _state} = Nodes.ApprovalGate.run(state, ctx)
    end
  end

  describe "Escalate" do
    test "pauses on first call and sets awaiting_auditor" do
      state =
        CodingLoop.initial_state(%{session_id: Ecto.UUID.generate()})
        |> Map.put(:decision, :escalate)

      assert {:wait, new_state} = Nodes.Escalate.run(state, %{})
      assert new_state[:awaiting_auditor] == true
    end

    test "proceeds on resume when awaiting_auditor is set" do
      state =
        CodingLoop.initial_state(%{session_id: Ecto.UUID.generate()})
        |> Map.put(:awaiting_auditor, true)

      ctx = %{auditor_completed: true}
      assert {:next, :default, new_state} = Nodes.Escalate.run(state, ctx)
      refute Map.has_key?(new_state, :awaiting_auditor)
    end
  end

  describe "Complete" do
    test "returns :end" do
      state = CodingLoop.initial_state(%{session_id: Ecto.UUID.generate()})
      assert {:end, ^state} = Nodes.Complete.run(state, %{})
    end
  end
end
