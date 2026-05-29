defmodule Synapsis.Agent.Nodes.OrchestrateTest do
  use Synapsis.Agent.DataCase, async: false

  alias Synapsis.{Repo, Session}
  alias Synapsis.Agent.Nodes.Orchestrate
  alias Synapsis.Session.Monitor

  test "pause decision is observed but does not stop the tool loop" do
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

    assert {:next, :continue, new_state} = Orchestrate.run(state, %{})
    assert new_state.decision == :pause

    refute_receive {"orchestrator_pause", _}, 50
    refute_receive {"session_status", _}, 50
    assert Repo.get!(Session, session.id).status == "streaming"
  end
end
