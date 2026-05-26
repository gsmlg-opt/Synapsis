defmodule Synapsis.Agent.Nodes.OrchestrateTest do
  use Synapsis.Agent.DataCase, async: false

  alias Synapsis.{Repo, Session}
  alias Synapsis.Agent.Nodes.Orchestrate
  alias Synapsis.Session.Monitor

  test "pause decision applies idle status and broadcasts the pause" do
    {:ok, session} =
      %Session{}
      |> Session.changeset(%{
        provider: "anthropic",
        model: "test-model",
        agent: "main",
        status: "streaming"
      })
      |> Repo.insert()

    Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session.id}")

    state = %{
      session_id: session.id,
      pending_text: "",
      tool_uses: [],
      iteration_count: 2,
      monitor: %{Monitor.new() | consecutive_empty_iterations: 2},
      decision: nil
    }

    assert {:next, :pause, new_state} = Orchestrate.run(state, %{})
    assert new_state.decision == :pause

    assert_receive {"orchestrator_pause", %{reason: reason}}
    assert reason =~ "waiting for user guidance"
    assert_receive {"session_status", %{status: "idle"}}
    assert Repo.get!(Session, session.id).status == "idle"
  end
end
