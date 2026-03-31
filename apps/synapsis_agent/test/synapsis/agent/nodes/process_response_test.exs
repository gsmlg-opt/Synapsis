defmodule Synapsis.Agent.Nodes.ProcessResponseTest do
  use Synapsis.Agent.DataCase, async: true

  alias Synapsis.Agent.Nodes.ProcessResponse

  setup do
    project =
      %Synapsis.Project{}
      |> Synapsis.Project.changeset(%{path: "/tmp/test-pr", slug: "test-pr"})
      |> Repo.insert!()

    session =
      %Synapsis.Session{}
      |> Synapsis.Session.changeset(%{
        title: "test",
        project_id: project.id,
        provider: "anthropic",
        model: "claude-sonnet-4-20250514"
      })
      |> Repo.insert!()

    %{session: session}
  end

  describe "run/2" do
    test "routes to :no_tools when tool_uses is empty", %{session: session} do
      state = %{
        session_id: session.id,
        pending_text: "",
        pending_tool_use: nil,
        pending_tool_input: "",
        pending_reasoning: "",
        tool_uses: []
      }

      assert {:next, :no_tools, _new_state} = ProcessResponse.run(state, %{})
    end

    test "routes to :has_tools when tool_uses is non-empty", %{session: session} do
      tool_use = %Synapsis.Part.ToolUse{
        tool: "file_read",
        tool_use_id: "tu_1",
        input: %{"path" => "/tmp/test"},
        status: :pending
      }

      state = %{
        session_id: session.id,
        pending_text: "Let me read that file.",
        pending_tool_use: nil,
        pending_tool_input: "",
        pending_reasoning: "",
        tool_uses: [tool_use]
      }

      assert {:next, :has_tools, _new_state} = ProcessResponse.run(state, %{})
    end
  end
end
