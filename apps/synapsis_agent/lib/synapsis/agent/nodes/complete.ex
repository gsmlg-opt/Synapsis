defmodule Synapsis.Agent.Nodes.Complete do
  @moduledoc "Final state — updates session status and broadcasts completion."
  @behaviour Synapsis.Agent.Runtime.Node

  require Logger

  @impl true
  @spec run(map(), map()) :: {:next, atom(), map()}
  def run(state, _ctx) do
    session_id = state.session_id
    status = if Map.get(state, :stream_error), do: "error", else: "idle"
    message = stream_error_message(state)

    # Persist terminal status to DB so page reloads show correct state.
    Synapsis.Session.Worker.Persistence.update_session_status(session_id, status)

    if message do
      Phoenix.PubSub.broadcast(
        Synapsis.PubSub,
        "session:#{session_id}",
        {"error", %{message: message}}
      )
    else
      Phoenix.PubSub.broadcast(
        Synapsis.PubSub,
        "session:#{session_id}",
        {"done", %{}}
      )
    end

    Phoenix.PubSub.broadcast(
      Synapsis.PubSub,
      "session:#{session_id}",
      {"session_status", %{status: status}}
    )

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
