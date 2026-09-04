defmodule Synapsis.Agent.RunEvents do
  @moduledoc """
  Critical and observational event append helpers for AgentRun.

  Critical lifecycle facts are stored under `coord/agent_run_events/` and must
  return storage errors to the caller. Observational appends may degrade.
  """

  require Logger

  alias Concord.Turso, as: KV
  alias Synapsis.Agent.Events.RunEvent
  alias Synapsis.AgentRun

  @prefix "coord/agent_run_events/"
  @by_id_prefix "coord/agent_run_event_ids/"
  @max_reason_bytes 512

  @spec append_critical(AgentRun.t(), RunEvent.t()) :: {:ok, RunEvent.t()} | {:error, term()}
  def append_critical(%AgentRun{} = run, %RunEvent{} = event) do
    unless RunEvent.critical_run?(event) do
      {:error, :not_critical}
    else
      do_append_critical(run, event)
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

  def append_run_created(%AgentRun{} = run),
    do: legacy_append(run, "agent_run_created", "run_created")

  def append_run_started(%AgentRun{} = run),
    do: legacy_append(run, "agent_run_started", "task_received")

  def append_run_completed(%AgentRun{} = run),
    do: legacy_append(run, "agent_run_completed", "task_completed")

  def append_run_failed(%AgentRun{} = run),
    do: legacy_append(run, "agent_run_failed", "task_failed")

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
    case KV.get(@by_id_prefix <> event_id) do
      {:ok, map} when is_map(map) -> map
      _ -> nil
    end
  end

  @spec list_for_run(String.t()) :: [map()]
  def list_for_run(run_id) when is_binary(run_id) do
    case KV.prefix_scan(@prefix <> run_id <> "/") do
      {:ok, pairs} ->
        pairs
        |> Enum.map(fn {_k, v} -> Concord.Compression.decompress(v) end)
        |> Enum.sort_by(& &1["sequence"])

      _ ->
        []
    end
  end

  defp do_append_critical(%AgentRun{} = run, %RunEvent{} = event) do
    case get_by_event_id(event.event_id) do
      %{"run_id" => existing_run_id} when existing_run_id == run.id ->
        {:ok, event}

      %{"run_id" => _} ->
        {:error, :event_id_conflict}

      nil ->
        put_critical(run, event)
    end
  end

  defp put_critical(%AgentRun{} = run, %RunEvent{} = event) do
    body = RunEvent.to_map(event)
    event_key = @prefix <> run.id <> "/" <> pad_seq(event.sequence) <> "-" <> event.event_id
    id_key = @by_id_prefix <> event.event_id
    id_body = %{"run_id" => run.id, "sequence" => event.sequence, "type" => event.type}

    with :ok <- put_kv(event_key, body),
         :ok <- put_kv(id_key, id_body) do
      _ = append_agent_event(run, event.type, Map.merge(base_payload(run), body))
      {:ok, event}
    end
  end

  defp put_kv(key, value) do
    case maybe_inject_event_failure() do
      {:error, reason} ->
        {:error, reason}

      :ok ->
        case KV.put(key, value) do
          :ok -> :ok
          {:ok, _} -> :ok
          other -> {:error, other}
        end
    end
  end

  defp maybe_inject_event_failure do
    case Process.get(:synapsis_run_events_put_result) do
      {:error, reason} -> {:error, reason}
      _ -> :ok
    end
  end

  defp pad_seq(seq) when is_integer(seq),
    do: seq |> Integer.to_string() |> String.pad_leading(12, "0")

  defp pad_seq(_), do: "000000000000"

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
