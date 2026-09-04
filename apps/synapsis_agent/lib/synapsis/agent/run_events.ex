defmodule Synapsis.Agent.RunEvents do
  @moduledoc "Best-effort append helpers for AgentRun lifecycle events."

  require Logger

  alias Synapsis.AgentRun

  @topic "agent:daemon"
  @max_payload_length 500

  def append_run_created(%AgentRun{} = run), do: append(run, "agent_run_created", "run_created")
  def append_run_started(%AgentRun{} = run), do: append(run, "agent_run_started", "task_received")

  def append_run_completed(%AgentRun{} = run),
    do: append(run, "agent_run_completed", "task_completed")

  def append_run_failed(%AgentRun{} = run), do: append(run, "agent_run_failed", "task_failed")

  def append_run_cancelled(%AgentRun{} = run),
    do: append(run, "agent_run_cancelled", "task_cancelled")

  def append_run_interrupted(%AgentRun{} = run),
    do: append(run, "agent_run_interrupted", "task_failed")

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

  def append_tool_event(%AgentRun{} = run, event) do
    append_agent_event(
      run,
      "agent_run_tool_event",
      Map.put(base_payload(run), "event", inspect(event))
    )
  end

  def append_dream_summary(%AgentRun{} = run, summary) when is_binary(summary) do
    payload = Map.put(base_payload(run), "summary", summary)
    append_agent_event(run, "agent_run_dream_summary", payload)
    append_memory_event(run, "summary_created", payload)
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
    payload = Map.put(payload, :routine_id, run.routine_id)
    if event == :failed, do: Map.put(payload, :error, run.error), else: payload
  end

  defp lifecycle_topic(:created), do: "agent.run.queued"
  defp lifecycle_topic(event), do: "agent.run.#{event}"

  defp bound_payload(payload) do
    Map.new(payload, fn
      {key, value} when is_binary(value) ->
        {key, String.slice(value, 0, @max_payload_length)}

      pair ->
        pair
    end)
  end

  defp normalize_result(:ok), do: :ok
  defp normalize_result({:ok, _value}), do: :ok
  defp normalize_result({:error, reason}), do: {:error, reason}
  defp normalize_result(_other), do: :ok

  defp append(%AgentRun{} = run, agent_event_type, memory_event_type) do
    payload = base_payload(run)
    append_agent_event(run, agent_event_type, payload)
    append_memory_event(run, memory_event_type, payload)
  end

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
