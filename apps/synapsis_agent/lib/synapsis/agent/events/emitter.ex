defmodule Synapsis.Agent.Events.Emitter do
  @moduledoc """
  Emits typed internal session/run events and derives existing UI PubSub projections.

  Internal consumers should match on `{:run_event, %RunEvent{}}`.
  LiveView/CLI continue to receive `{"done", %{}}, {"error", %{}}`, and
  `{"session_status", %{}}`.
  """

  alias Synapsis.Agent.Events.RunEvent

  @topic_prefix "session:"

  @doc "Emit `session.completed` plus `done` / idle UI projections."
  @spec emit_session_completed(String.t(), keyword()) :: RunEvent.t()
  def emit_session_completed(session_id, opts \\ []) when is_binary(session_id) do
    event =
      RunEvent.new("session.completed",
        session_id: session_id,
        run_id: Keyword.get(opts, :run_id),
        correlation_id: Keyword.get(opts, :correlation_id),
        causation_id: Keyword.get(opts, :causation_id),
        payload: Map.merge(%{"status" => "idle"}, Keyword.get(opts, :payload, %{}))
      )

    broadcast_typed(session_id, event)
    broadcast_ui(session_id, "done", %{})
    broadcast_ui(session_id, "session_status", %{status: "idle"})
    event
  end

  @doc "Emit `session.failed` plus `error` / error UI projections."
  @spec emit_session_failed(String.t(), String.t(), keyword()) :: RunEvent.t()
  def emit_session_failed(session_id, message, opts \\ [])
      when is_binary(session_id) and is_binary(message) do
    event =
      RunEvent.new("session.failed",
        session_id: session_id,
        run_id: Keyword.get(opts, :run_id),
        correlation_id: Keyword.get(opts, :correlation_id),
        causation_id: Keyword.get(opts, :causation_id),
        payload:
          Map.merge(
            %{"status" => "error", "message" => message},
            Keyword.get(opts, :payload, %{})
          )
      )

    broadcast_typed(session_id, event)
    broadcast_ui(session_id, "error", %{message: message})
    broadcast_ui(session_id, "session_status", ui_status_payload("error", opts))
    event
  end

  @doc """
  Emit `session.turn_completed` for conversational loops that stay alive.

  Still derives `done` / idle UI projections so LiveView behaviour is unchanged,
  but internal waiters must not treat this as a session-terminal outcome.
  """
  @spec emit_turn_completed(String.t(), keyword()) :: RunEvent.t()
  def emit_turn_completed(session_id, opts \\ []) when is_binary(session_id) do
    event =
      RunEvent.new("session.turn_completed",
        session_id: session_id,
        run_id: Keyword.get(opts, :run_id),
        correlation_id: Keyword.get(opts, :correlation_id),
        causation_id: Keyword.get(opts, :causation_id),
        payload: Map.merge(%{"status" => "idle"}, Keyword.get(opts, :payload, %{}))
      )

    broadcast_typed(session_id, event)
    broadcast_ui(session_id, "done", %{})
    broadcast_ui(session_id, "session_status", %{status: "idle"})
    event
  end

  @doc "Emit a timed-out session terminal without inventing a successful transcript."
  @spec emit_session_timed_out(String.t(), String.t(), keyword()) :: RunEvent.t()
  def emit_session_timed_out(session_id, message, opts \\ [])
      when is_binary(session_id) and is_binary(message) do
    event =
      RunEvent.new("session.timed_out",
        session_id: session_id,
        run_id: Keyword.get(opts, :run_id),
        correlation_id: Keyword.get(opts, :correlation_id),
        causation_id: Keyword.get(opts, :causation_id),
        payload:
          Map.merge(
            %{"status" => "error", "message" => message},
            Keyword.get(opts, :payload, %{})
          )
      )

    broadcast_typed(session_id, event)
    broadcast_ui(session_id, "error", %{message: message})
    broadcast_ui(session_id, "session_status", %{status: "error"})
    event
  end

  defp broadcast_typed(session_id, event) do
    Phoenix.PubSub.broadcast(Synapsis.PubSub, topic(session_id), {:run_event, event})
  end

  defp broadcast_ui(session_id, event, payload) do
    Phoenix.PubSub.broadcast(Synapsis.PubSub, topic(session_id), {event, payload})
  end

  defp topic(session_id), do: @topic_prefix <> session_id

  defp ui_status_payload(status, opts) do
    case Keyword.get(opts, :reason) do
      nil -> %{status: status}
      reason -> %{status: status, reason: to_string(reason)}
    end
  end
end
