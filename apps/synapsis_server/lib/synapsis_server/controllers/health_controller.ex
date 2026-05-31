defmodule SynapsisServer.HealthController do
  use SynapsisServer, :controller

  @repo_timeout 1_000

  def show(conn, _params) do
    checks = %{
      repo: check_repo(),
      pubsub: check_process(Synapsis.PubSub),
      scheduler: check_scheduler(),
      tool_registry: check_process(Synapsis.Tool.Registry),
      provider_registry: check_process(Synapsis.Provider.Registry),
      session_supervisor: check_process(Synapsis.Session.DynamicSupervisor),
      agent_supervisor: check_process(Synapsis.Agent.Supervisor),
      agent_daemon: check_agent_daemon(),
      endpoint: check_process(SynapsisServer.Endpoint)
    }

    payload =
      checks
      |> Map.put(:ok, healthy?(checks))
      |> Map.put(:version, version())
      |> Map.put(:scheduler_entries, scheduler_entries())

    json(conn, payload)
  end

  defp check_repo do
    case Synapsis.Repo.query("SELECT 1", [], timeout: @repo_timeout) do
      {:ok, _} -> "ok"
      {:error, reason} -> "error: #{inspect(reason)}"
    end
  rescue
    error -> "error: #{Exception.message(error)}"
  catch
    :exit, reason -> "error: #{inspect(reason)}"
  end

  defp check_scheduler do
    if Code.ensure_loaded?(Synapsis.Agent.Heartbeat.LocalScheduler) do
      check_process(Synapsis.Agent.Heartbeat.LocalScheduler)
    else
      "not_configured"
    end
  end

  defp scheduler_entries do
    if Code.ensure_loaded?(Synapsis.Agent.Heartbeat.LocalScheduler) do
      try do
        Synapsis.Agent.Heartbeat.LocalScheduler.status()
        |> Enum.map(fn e ->
          %{
            name: e.name,
            schedule: e.schedule,
            next_run_at: if(e.next_run_at, do: DateTime.to_iso8601(e.next_run_at))
          }
        end)
      rescue
        _ -> []
      end
    else
      []
    end
  end

  defp check_agent_daemon do
    if Code.ensure_loaded?(Synapsis.Agent.Daemon) do
      check_process(Synapsis.Agent.Daemon)
    else
      "error: not_started"
    end
  end

  defp check_process(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> "ok"
      nil -> "error: not_started"
    end
  end

  defp healthy?(checks) do
    Enum.all?(checks, fn
      {:scheduler, status} -> status in ["ok", "not_configured"]
      {:agent_daemon, "error: not_started"} -> false
      {_name, "ok"} -> true
      {_name, _status} -> false
    end)
  end

  defp version do
    :synapsis_server
    |> Application.spec(:vsn)
    |> case do
      nil -> "unknown"
      version -> to_string(version)
    end
  end
end
