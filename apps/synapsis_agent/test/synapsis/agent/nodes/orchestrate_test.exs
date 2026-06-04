defmodule Synapsis.Agent.Nodes.OrchestrateTest do
  use Synapsis.Agent.DataCase, async: false

  alias Synapsis.Session
  alias Synapsis.Agent.Nodes.Orchestrate
  alias Synapsis.Session.Monitor

  test "pause decision is observed but does not stop the tool loop" do
    session =
      %Session{}
      |> Session.changeset(%{
        provider: "anthropic",
        model: "test-model",
        agent: "main",
        status: "streaming"
      })
      |> Ecto.Changeset.apply_changes()
      |> Map.put(:id, Ecto.UUID.generate())

    :ok = Session.Store.put_meta(session.id, Session.to_meta(session))

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
    {:ok, meta} = Session.Store.get_meta(session.id)
    assert Session.from_meta(meta).status == "streaming"
  end
end
