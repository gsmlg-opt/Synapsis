defmodule SynapsisServer.AgentDaemonEvent do
  @moduledoc "Maps internal daemon PubSub envelopes to public transport events."

  @external_names %{
    "agent.daemon.status" => "daemon_status",
    "agent.run.queued" => "run_queued",
    "agent.run.started" => "run_started",
    "agent.run.completed" => "run_completed",
    "agent.run.failed" => "run_failed",
    "agent.routine.triggered" => "routine_triggered",
    "backplane.sync.started" => "backplane_sync_started",
    "backplane.sync.completed" => "backplane_sync_completed",
    "backplane.sync.failed" => "backplane_sync_failed",
    "backplane.capabilities.updated" => "capabilities_updated"
  }

  @spec map(term()) :: {:ok, {String.t(), map()}} | :ignore
  def map({:agent_daemon_event, envelope}) when is_map(envelope) do
    case Map.fetch(@external_names, Map.get(envelope, :event)) do
      {:ok, external_name} -> {:ok, {external_name, Map.delete(envelope, :event)}}
      :error -> :ignore
    end
  end

  def map(_message), do: :ignore
end
