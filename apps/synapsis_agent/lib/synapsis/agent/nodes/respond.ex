defmodule Synapsis.Agent.Nodes.Respond do
  @moduledoc """
  Finalises a conversational response and loops back to receive_message.

  Unlike `Complete` (which terminates the graph), `Respond` keeps the
  conversation alive: it broadcasts turn-complete typed events plus the
  done/idle UI projections, resets per-turn state, and returns
  `{:next, :loop, state}` so the graph runner advances to the :receive edge
  defined in ConversationalLoop.
  """
  @behaviour Synapsis.Agent.Runtime.Node

  require Logger

  alias Synapsis.Agent.Events.Emitter

  @impl true
  @spec run(map(), map()) :: {:next, atom(), map()}
  def run(state, _ctx) do
    session_id = state.session_id

    Synapsis.Session.Worker.Persistence.update_session_status(session_id, "idle")
    Emitter.emit_turn_completed(session_id)

    new_state =
      Map.merge(state, %{
        pending_text: "",
        pending_tool_use: nil,
        pending_tool_input: "",
        pending_reasoning: "",
        pending_reasoning_signature: "",
        tool_uses: [],
        user_input: nil,
        iteration_count: state.iteration_count + 1
      })

    Logger.info("conversational_response_complete",
      session_id: session_id,
      iteration: new_state.iteration_count
    )

    {:next, :loop, new_state}
  end
end
