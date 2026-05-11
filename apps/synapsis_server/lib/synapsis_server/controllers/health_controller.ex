defmodule SynapsisServer.HealthController do
  use SynapsisServer, :controller

  @repo_timeout 1_000

  def show(conn, _params) do
    checks = %{
      repo: check_repo(),
      pubsub: check_process(Synapsis.PubSub),
      oban: check_oban(),
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

  defp check_oban do
    case Application.fetch_env(:synapsis_core, Oban) do
      {:ok, false} -> "disabled"
      {:ok, _config} -> check_process(Oban)
      :error -> "not_configured"
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
      {:oban, status} -> status in ["ok", "disabled", "not_configured"]
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
