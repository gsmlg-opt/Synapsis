defmodule Synapsis.Agent.RunEvents do
  @moduledoc """
  Critical and observational event append helpers for AgentRun.

  Critical lifecycle facts are stored under `coord/agent_run_events/` and must
  return storage errors to the caller. Observational appends may degrade.
  """

  require Logger

  alias Synapsis.Agent.Events.RunEvent
  alias Synapsis.AgentRun
  alias Synapsis.AgentRun.Store
  @max_reason_bytes 512
  @topic "agent:daemon"
  @max_payload_length 500

  @spec append_critical(AgentRun.t(), RunEvent.t()) :: {:ok, RunEvent.t()} | {:error, term()}
  def append_critical(%AgentRun{} = run, %RunEvent{} = event) do
    unless RunEvent.critical_run?(event) do
      {:error, :not_critical}
    else
      with {:ok, _updated} <- Synapsis.Agent.Runs.apply_event(run, event), do: {:ok, event}
    end
  end

  @spec append_observational(AgentRun.t(), String.t(), map()) :: :ok
  def append_observational(%AgentRun{} = run, event_type, payload)
      when is_binary(event_type) and is_map(payload) do
    _ = append_agent_event(run, event_type, payload)
    :ok
  rescue
    error ->
      Logger.warning("agent_run_observational_append_failed", reason: inspect(error))
      :ok
  end

  @doc false
  def observe_critical(%AgentRun{} = run, %RunEvent{} = event) do
    append_observational(run, event.type, Map.merge(base_payload(run), RunEvent.to_map(event)))
  end

  def append_run_created(%AgentRun{} = run),
    do: legacy_append(run, "agent_run_created", "run_created")

  def append_run_started(%AgentRun{} = run),
    do: legacy_append(run, "agent_run_started", "task_received")

  def append_run_completed(%AgentRun{} = run),
    do: legacy_append(run, "agent_run_completed", "task_completed")

  def append_run_failed(%AgentRun{} = run),
    do: legacy_append(run, "agent_run_failed", "task_failed")

  def append_run_cancelled(%AgentRun{} = run),
    do: legacy_append(run, "agent_run_cancelled", "task_cancelled")

  def append_run_interrupted(%AgentRun{} = run),
    do: legacy_append(run, "agent_run_interrupted", "task_failed")

  def append_lifecycle(adapter, event, %AgentRun{} = run) do
    append_function = String.to_existing_atom("append_run_#{event}")
    normalize_result(apply(adapter, append_function, [run]))
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  def publish_lifecycle(event, %AgentRun{} = run, payload \\ %{}) do
    publish(lifecycle_topic(event), run, lifecycle_payload(event, run, payload))
  end

  def publish_routine_triggered(routine, %AgentRun{} = run) when is_map(routine) do
    Phoenix.PubSub.broadcast(
      Synapsis.PubSub,
      @topic,
      {:agent_daemon_event,
       %{
         event: "agent.routine.triggered",
         routine_id: value(routine, :id),
         routine_name: value(routine, :name),
         kind: value(routine, :kind),
         run_id: run.id,
         status: run.status,
         at: DateTime.utc_now()
       }}
    )
  end

  def publish_routine_updated(routine) when is_map(routine) do
    publish_routine_updated(value(routine, :id), value(routine, :kind) || "heartbeat")
  end

  def publish_routine_updated(id, kind) when is_binary(id) do
    Phoenix.PubSub.broadcast(
      Synapsis.PubSub,
      @topic,
      {:agent_daemon_event,
       %{event: "agent.routine.updated", routine_id: id, kind: kind, at: DateTime.utc_now()}}
    )
  end

  def publish_status(adapter, status, sequence) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :publish_daemon_status, 2) do
      adapter.publish_daemon_status(status, sequence)
    else
      Phoenix.PubSub.broadcast(
        Synapsis.PubSub,
        @topic,
        {:agent_daemon_event,
         %{
           event: "agent.daemon.status",
           status: status,
           sequence: sequence,
           at: DateTime.utc_now()
         }}
      )
    end
  end

  @doc """
  Persist a structured tool event (observational durability class).
  """
  @spec append_tool_event(AgentRun.t(), map() | keyword()) :: :ok
  def append_tool_event(%AgentRun{} = run, event) when is_list(event) do
    append_tool_event(run, Map.new(event))
  end

  def append_tool_event(%AgentRun{} = run, event) when is_map(event) do
    payload =
      base_payload(run)
      |> Map.merge(structured_tool_payload(event))

    append_observational(run, "agent_run_tool_event", payload)
  end

  def append_dream_summary(%AgentRun{} = run, summary) when is_binary(summary) do
    payload = Map.put(base_payload(run), "summary", summary)
    append_observational(run, "agent_run_dream_summary", payload)
    append_memory_event(run, "summary_created", payload)
  end

  @spec get_by_event_id(String.t()) :: map() | nil
  def get_by_event_id(event_id) when is_binary(event_id) do
    case Store.event_index(event_id) do
      {:ok, map} when is_map(map) -> map
      _ -> nil
    end
  end

  @spec list_for_run(String.t()) :: [map()]
  def list_for_run(run_id) when is_binary(run_id) do
    case Store.list_events(run_id) do
      {:ok, events} -> events
      _ -> []
    end
  end

  defp legacy_append(%AgentRun{} = run, agent_event_type, memory_event_type) do
    payload = base_payload(run)
    append_observational(run, agent_event_type, payload)
    append_memory_event(run, memory_event_type, payload)
  end

  defp structured_tool_payload(event) do
    reason =
      event
      |> fetch([
        :denial_or_failure_reason,
        "denial_or_failure_reason",
        :reason,
        "reason",
        :error,
        "error"
      ])
      |> truncate(@max_reason_bytes)

    %{
      "tool_name" => fetch(event, [:tool_name, "tool_name", :name, "name"]),
      "class" => fetch(event, [:class, "class", :risk_level, "risk_level"]),
      "status" => fetch(event, [:status, "status"]),
      "duration_ms" => fetch(event, [:duration_ms, "duration_ms"]),
      "denial_or_failure_reason" => reason,
      "correlation_id" => fetch(event, [:correlation_id, "correlation_id"])
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp publish(event, run, payload) do
    Phoenix.PubSub.broadcast(
      Synapsis.PubSub,
      @topic,
      {:agent_daemon_event,
       %{
         event: event,
         run_id: run.id,
         kind: run.kind,
         status: run.status,
         payload: bound_payload(payload),
         at: DateTime.utc_now()
       }}
    )
  end

  defp lifecycle_payload(event, run, payload) do
    payload =
      payload
      |> Map.put(:routine_id, run.routine_id)
      |> Map.put(:started_at, encode_datetime(run.started_at))
      |> Map.put(:inserted_at, encode_datetime(run.inserted_at))

    if event == :failed, do: Map.put(payload, :error, run.error), else: payload
  end

  defp encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp encode_datetime(_datetime), do: nil

  defp lifecycle_topic(:created), do: "agent.run.queued"
  defp lifecycle_topic(event), do: "agent.run.#{event}"

  defp bound_payload(payload) do
    Map.new(payload, fn
      {key, value} when is_binary(value) -> {key, String.slice(value, 0, @max_payload_length)}
      pair -> pair
    end)
  end

  defp normalize_result(:ok), do: :ok
  defp normalize_result({:ok, _value}), do: :ok
  defp normalize_result({:error, reason}), do: {:error, reason}
  defp normalize_result(_other), do: :ok

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp fetch(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  defp truncate(nil, _), do: nil

  defp truncate(value, max) when is_binary(value) do
    if byte_size(value) <= max, do: value, else: binary_part(value, 0, max) <> "…"
  end

  defp truncate(value, max), do: value |> inspect() |> truncate(max)

  defp append_agent_event(%AgentRun{} = run, event_type, payload) do
    if Code.ensure_loaded?(Synapsis.AgentEvents) and
         function_exported?(Synapsis.AgentEvents, :append, 1) do
      case Synapsis.AgentEvents.append(%{
             event_type: event_type,
             agent_id: run.assistant_name || "daemon",
             work_id: run.id,
             payload: payload
           }) do
        :ok -> :ok
        {:error, reason} -> log_failure("agent_event", reason)
      end
    end
  rescue
    error -> log_failure("agent_event", error)
  end

  defp append_memory_event(%AgentRun{} = run, event_type, payload) do
    if Code.ensure_loaded?(Synapsis.Memory) and
         function_exported?(Synapsis.Memory, :append_event, 1) do
      {scope, scope_id} = memory_scope(run)

      Synapsis.Memory.append_event(%{
        scope: scope,
        scope_id: scope_id,
        agent_id: run.assistant_name || "daemon",
        run_id: run.id,
        type: event_type,
        payload: payload
      })

      :ok
    end
  rescue
    error -> log_failure("memory_event", error)
  end

  defp base_payload(%AgentRun{} = run) do
    %{
      "run_id" => run.id,
      "kind" => run.kind,
      "status" => run.status,
      "source" => run.source,
      "assistant_name" => run.assistant_name,
      "session_id" => run.session_id,
      "heartbeat_id" => run.heartbeat_id,
      "routine_id" => run.routine_id
    }
  end

  defp memory_scope(%AgentRun{session_id: session_id})
       when is_binary(session_id) and session_id != "" do
    {"session", session_id}
  end

  defp memory_scope(_run), do: {"agent", "daemon"}

  defp log_failure(target, reason) do
    Logger.warning("agent_run_event_append_failed", target: target, reason: inspect(reason))
    :ok
  end
end
