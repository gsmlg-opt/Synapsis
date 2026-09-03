defmodule Synapsis.Agent.Nodes.Complete do
  @moduledoc "Final state — updates session status and broadcasts completion."
  @behaviour Synapsis.Agent.Runtime.Node

  require Logger

  alias Synapsis.Agent.Events.Emitter

  @impl true
  @spec run(map(), map()) :: {:next, atom(), map()}
  def run(state, _ctx) do
    session_id = state.session_id
    status = if Map.get(state, :stream_error), do: "error", else: "idle"
    message = stream_error_message(state)

    # Persist terminal status so page reloads show correct state.
    Synapsis.Session.Worker.Persistence.update_session_status(session_id, status)

    if message do
      Emitter.emit_session_failed(session_id, message)
    else
      Emitter.emit_session_completed(session_id)
    end

    Logger.info("coding_loop_complete",
      session_id: session_id,
      iterations: state.iteration_count
    )

    {:next, :default, state}
  end

  defp stream_error_message(%{stream_error: reason}) when is_binary(reason),
    do: "Provider error: #{reason}"

  defp stream_error_message(%{stream_error: reason}), do: "Provider error: #{inspect(reason)}"
  defp stream_error_message(_state), do: nil
end
