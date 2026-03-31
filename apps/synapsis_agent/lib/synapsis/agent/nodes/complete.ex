defmodule Synapsis.Agent.Nodes.Complete do
  @moduledoc "Final state — updates session status and broadcasts completion."
  @behaviour Synapsis.Agent.Runtime.Node

  require Logger

  @impl true
  @spec run(map(), map()) :: {:end, map()}
  def run(state, _ctx) do
    session_id = state.session_id

    # Persist idle status to DB so page reloads show correct state
    Synapsis.Session.Worker.Persistence.update_session_status(session_id, "idle")

    Phoenix.PubSub.broadcast(
      Synapsis.PubSub,
      "session:#{session_id}",
      {"done", %{}}
    )

    Phoenix.PubSub.broadcast(
      Synapsis.PubSub,
      "session:#{session_id}",
      {"session_status", %{status: "idle"}}
    )

    Logger.info("coding_loop_complete",
      session_id: session_id,
      iterations: state.iteration_count
    )

    {:end, state}
  end
end
