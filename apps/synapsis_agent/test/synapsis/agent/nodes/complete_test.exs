defmodule Synapsis.Agent.Nodes.CompleteTest do
  use Synapsis.Agent.DataCase, async: true

  alias Synapsis.Agent.Nodes.Complete

  setup do
    project =
      %Synapsis.Project{}
      |> Synapsis.Project.changeset(%{
        path: "/tmp/test-comp",
        slug: "test-comp",
        name: "test-comp"
      })
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
    test "ends the graph and returns state", %{session: session} do
      state = %{
        session_id: session.id,
        iteration_count: 5
      }

      assert {:end, ^state} = Complete.run(state, %{})
    end

    test "broadcasts done and session_status events", %{session: session} do
      Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session.id}")

      state = %{
        session_id: session.id,
        iteration_count: 3
      }

      Complete.run(state, %{})

      assert_receive {"done", %{}}
      assert_receive {"session_status", %{status: "idle"}}
    end
  end
end
