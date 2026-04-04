defmodule Synapsis.Agent.Nodes.CompactContextTest do
  use Synapsis.Agent.DataCase, async: true

  alias Synapsis.Agent.Nodes.CompactContext
  alias Synapsis.Agent.Graphs.CodingLoop

  setup do
    project =
      %Synapsis.Project{}
      |> Synapsis.Project.changeset(%{path: "/tmp/test-cc", slug: "test-cc", name: "test-cc"})
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
    test "proceeds with :default when no compaction needed", %{session: session} do
      state =
        CodingLoop.initial_state(%{session_id: session.id})
        |> Map.put(:agent_config, %{model: "claude-sonnet-4-20250514"})

      assert {:next, :default, ^state} = CompactContext.run(state, %{})
    end

    test "proceeds with :default even when compaction fails", %{session: _session} do
      # Use a non-existent session to trigger error path
      state =
        CodingLoop.initial_state(%{session_id: Ecto.UUID.generate()})
        |> Map.put(:agent_config, %{model: "claude-sonnet-4-20250514"})

      assert {:next, :default, _state} = CompactContext.run(state, %{})
    end
  end
end
