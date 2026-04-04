defmodule Synapsis.Agent.Nodes.ToolExecuteTest do
  use Synapsis.Agent.DataCase, async: true

  alias Synapsis.Agent.Nodes.ToolExecute
  alias Synapsis.Agent.Graphs.CodingLoop

  describe "run/2" do
    test "pauses on first call when approved tools exist" do
      tool_use = %Synapsis.Part.ToolUse{
        tool: "file_read",
        tool_use_id: "tu_1",
        input: %{"path" => "/tmp/test"},
        status: :pending
      }

      state =
        CodingLoop.initial_state(%{session_id: Ecto.UUID.generate()})
        |> Map.put(:classified_tools, [{:auto_approved, tool_use}])
        |> Map.put(:tool_call_hashes, MapSet.new())

      assert {:wait, new_state} = ToolExecute.run(state, %{})
      assert new_state[:awaiting_tools] == true
    end

    test "proceeds on resume when awaiting_tools is set" do
      state =
        CodingLoop.initial_state(%{session_id: Ecto.UUID.generate()})
        |> Map.put(:awaiting_tools, true)
        |> Map.put(:classified_tools, [])
        |> Map.put(:tool_uses, [])

      assert {:next, :default, new_state} = ToolExecute.run(state, %{})
      refute Map.has_key?(new_state, :awaiting_tools)
      assert new_state.tool_uses == []
    end

    test "proceeds directly when all tools are denied" do
      tool_use = %Synapsis.Part.ToolUse{
        tool: "bash_exec",
        tool_use_id: "tu_1",
        input: %{"command" => "rm -rf /"},
        status: :pending
      }

      session_id = Ecto.UUID.generate()

      # Create session for ResponseFlusher
      project =
        %Synapsis.Project{}
        |> Synapsis.Project.changeset(%{path: "/tmp/test-te", slug: "test-te", name: "test-te"})
        |> Repo.insert!()

      %Synapsis.Session{}
      |> Synapsis.Session.changeset(%{
        id: session_id,
        title: "test",
        project_id: project.id,
        provider: "anthropic",
        model: "claude-sonnet-4-20250514"
      })
      |> Repo.insert!()

      state =
        CodingLoop.initial_state(%{session_id: session_id})
        |> Map.put(:classified_tools, [{:denied, tool_use}])
        |> Map.put(:tool_call_hashes, MapSet.new())

      assert {:next, :default, new_state} = ToolExecute.run(state, %{})
      assert new_state.tool_uses == []
    end
  end
end
