defmodule Synapsis.Agent.Nodes.BuildPromptTest do
  use Synapsis.Agent.DataCase, async: true

  alias Synapsis.Agent.Nodes.BuildPrompt
  alias Synapsis.Agent.Graphs.CodingLoop

  setup do
    project =
      %Synapsis.Project{}
      |> Synapsis.Project.changeset(%{path: "/tmp/test-bp", slug: "test-bp", name: "test-bp"})
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
    test "builds request and advances to :default", %{session: session} do
      state =
        CodingLoop.initial_state(%{session_id: session.id})
        |> Map.put(:agent_config, %{
          name: "test",
          system_prompt: "You are a test agent.",
          model: "claude-sonnet-4-20250514",
          project_id: nil
        })

      assert {:next, :default, new_state} = BuildPrompt.run(state, %{provider: "anthropic"})
      assert is_map(new_state[:request])
      assert new_state.user_input == nil
    end
  end
end
