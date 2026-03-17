defmodule Synapsis.Agent.Nodes.Complete do
  @moduledoc "Final state — updates session status and broadcasts completion."
  @behaviour Synapsis.Agent.Runtime.Node

  require Logger

  @impl true
  def run(state, _ctx) do
    session_id = state.session_id

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
