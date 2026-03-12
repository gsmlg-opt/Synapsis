defmodule Synapsis.Memory.Writer do
  @moduledoc """
  PubSub subscriber that captures domain events and persists them as memory events.
  Implements the observer pattern — the agent loop does not change.
  """
  use GenServer
  require Logger

  @pubsub Synapsis.PubSub

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Subscribe to wildcard-matching topics via a registry-like pattern
    # We subscribe to specific topics dynamically as sessions start
    {:ok, %{subscriptions: MapSet.new()}}
  end

  @doc "Subscribe to events for a specific session."
  def subscribe_session(session_id) do
    GenServer.cast(__MODULE__, {:subscribe_session, session_id})
  end

  @doc "Unsubscribe from events for a specific session."
  def unsubscribe_session(session_id) do
    GenServer.cast(__MODULE__, {:unsubscribe_session, session_id})
  end

  @impl true
  def handle_cast({:subscribe_session, session_id}, state) do
    unless MapSet.member?(state.subscriptions, session_id) do
      Phoenix.PubSub.subscribe(@pubsub, "session:#{session_id}")
      Phoenix.PubSub.subscribe(@pubsub, "tool_effects:#{session_id}")
    end

    {:noreply, %{state | subscriptions: MapSet.put(state.subscriptions, session_id)}}
  end

  def handle_cast({:unsubscribe_session, session_id}, state) do
    Phoenix.PubSub.unsubscribe(@pubsub, "session:#{session_id}")
    Phoenix.PubSub.unsubscribe(@pubsub, "tool_effects:#{session_id}")
    {:noreply, %{state | subscriptions: MapSet.delete(state.subscriptions, session_id)}}
  end

  # ── Tool effects ────────────────────────────────────────────────────

  @impl true
  def handle_info({:tool_effect, effect_type, payload}, state) do
    persist_event(%{
      scope: "session",
      scope_id: extract_session_id(payload),
      agent_id: Map.get(payload, :agent_id, "unknown"),
      type: map_tool_effect(effect_type),
      importance: importance_for(effect_type),
      payload: sanitize_payload(payload)
    })

    {:noreply, state}
  end

  # ── Session events ─────────────────────────────────────────────────

  def handle_info({:message_complete, session_id, _message}, state) do
    persist_event(%{
      scope: "session",
      scope_id: session_id,
      agent_id: "session_worker",
      type: "message_added",
      importance: 0.3,
      payload: %{}
    })

    {:noreply, state}
  end

  def handle_info({:status_changed, session_id, status}, state) do
    type =
      case status do
        :streaming -> "run_created"
        :idle -> "task_completed"
        :error -> "task_failed"
        _ -> nil
      end

    if type do
      persist_event(%{
        scope: "session",
        scope_id: session_id,
        agent_id: "session_worker",
        type: type,
        importance: if(status == :error, do: 0.8, else: 0.5),
        payload: %{status: to_string(status)}
      })
    end

    {:noreply, state}
  end

  # Catch-all for unknown messages
  def handle_info(_msg, state), do: {:noreply, state}

  # ── Internals ───────────────────────────────────────────────────────

  defp persist_event(attrs) do
    case Synapsis.Memory.append_event(attrs) do
      {:ok, _event} ->
        :ok

      {:error, changeset} ->
        Logger.warning("memory_event_persist_failed",
          error: inspect(changeset.errors),
          type: Map.get(attrs, :type)
        )
    end
  end

  defp map_tool_effect(:file_changed), do: "tool_succeeded"
  defp map_tool_effect(:tool_called), do: "tool_called"
  defp map_tool_effect(:tool_result), do: "tool_succeeded"
  defp map_tool_effect(:tool_error), do: "tool_failed"
  defp map_tool_effect(other), do: to_string(other)

  defp importance_for(:tool_error), do: 0.8
  defp importance_for(:file_changed), do: 0.6
  defp importance_for(_), do: 0.5

  defp extract_session_id(%{session_id: id}) when is_binary(id), do: id
  defp extract_session_id(_), do: "unknown"

  defp sanitize_payload(payload) when is_map(payload) do
    payload
    |> Map.drop([:api_key, :secret, :token, :password, :credentials])
    |> Map.new(fn {k, v} -> {to_string(k), safe_value(v)} end)
  end

  defp safe_value(v) when is_atom(v), do: to_string(v)
  defp safe_value(v) when is_struct(v), do: inspect(v)
  defp safe_value(v) when is_tuple(v), do: inspect(v)
  defp safe_value(v) when is_pid(v), do: inspect(v)
  defp safe_value(v) when is_reference(v), do: inspect(v)
  defp safe_value(v) when is_function(v), do: "#Function"
  defp safe_value(v), do: v
end
