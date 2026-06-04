defmodule Synapsis.Agent.RunEvents do
  @moduledoc "Best-effort append helpers for AgentRun lifecycle events."

  require Logger

  alias Synapsis.AgentRun

  def append_run_created(%AgentRun{} = run), do: append(run, "agent_run_created", "run_created")
  def append_run_started(%AgentRun{} = run), do: append(run, "agent_run_started", "task_received")

  def append_run_completed(%AgentRun{} = run),
    do: append(run, "agent_run_completed", "task_completed")

  def append_run_failed(%AgentRun{} = run), do: append(run, "agent_run_failed", "task_failed")

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
