defmodule Synapsis.Agent.Nodes.ToolDispatchTest do
  use Synapsis.Agent.DataCase, async: true

  alias Synapsis.Agent.Nodes.ToolDispatch

  setup do
    project =
      %Synapsis.Project{}
      |> Synapsis.Project.changeset(%{path: "/tmp/test-td", slug: "test-td"})
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

    %{session: session, project: project}
  end

  describe "run/2" do
    test "routes to :all_approved when no tools need approval", %{session: session} do
      state = %{
        session_id: session.id,
        tool_uses: [],
        monitor: %Synapsis.Session.Monitor{},
        agent_config: %{name: "test"}
      }

      assert {:next, :all_approved, new_state} = ToolDispatch.run(state, %{})
      assert new_state[:classified_tools] == []
    end

    test "routes to :needs_approval for destructive tools", %{session: session} do
      tool_use = %Synapsis.Part.ToolUse{
        tool: "bash_exec",
        tool_use_id: "tu_1",
        input: %{"command" => "rm -rf /"},
        status: :pending
      }

      state = %{
        session_id: session.id,
        tool_uses: [tool_use],
        monitor: %Synapsis.Session.Monitor{},
        agent_config: %{name: "test"}
      }

      assert {:next, selector, new_state} = ToolDispatch.run(state, %{})
      assert selector in [:needs_approval, :all_approved]
      assert is_list(new_state[:classified_tools])
    end
  end
end
