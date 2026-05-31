defmodule SynapsisCore.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    optional_children =
      [SynapsisPlugin.Supervisor]
      |> Enum.filter(&Code.ensure_loaded?/1)

    oban_child =
      case Application.fetch_env!(:synapsis_core, Oban) do
        false ->
          []

        oban_config ->
          case Application.ensure_all_started(:oban) do
            {:ok, _} ->
              [{Oban, oban_config}]

            {:error, _} ->
              Logger.warning("oban_start_skipped", reason: "oban application not available")
              []
          end
      end

    children =
      [
        Synapsis.Repo,
        {Phoenix.PubSub, name: Synapsis.PubSub},
        {Task.Supervisor, name: Synapsis.Provider.TaskSupervisor},
        Synapsis.Provider.Registry,
        {Task.Supervisor, name: Synapsis.Tool.TaskSupervisor},
        Synapsis.Tool.Registry,
        {Registry, keys: :unique, name: Synapsis.FileWatcher.Registry},
        Synapsis.Config.Store.Supervisor,
        Synapsis.Memory.Supervisor
      ] ++
        oban_child ++
        maybe_child(Synapsis.Workspace.GC) ++
        optional_children

    opts = [strategy: :one_for_one, name: SynapsisCore.Supervisor]
    result = Supervisor.start_link(children, opts)

    case result do
      {:ok, _pid} ->
        try do
          Synapsis.Providers.load_all_into_registry()
        rescue
          e in [RuntimeError, Ecto.QueryError, DBConnection.ConnectionError] ->
            Logger.warning("provider_registry_load_failed", error: Exception.message(e))
        end

        register_env_providers()
        seed_default_agents()
        seed_heartbeat_templates()
        sync_heartbeat_scheduler()

        maybe_apply(SynapsisPlugin.Loader, :start_auto_plugins, [])

        result

      other ->
        other
    end
  end

  @env_provider_names ~w(anthropic openai openai-sub google moonshot-ai moonshot-cn zhipu-ai zhipu-cn zhipu-coding minimax-io minimax-cn openrouter)

  defp maybe_child(mod) do
    if Code.ensure_loaded?(mod) do
      [mod]
    else
      []
    end
  end

  defp maybe_apply(mod, fun, args) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, length(args)) do
      apply(mod, fun, args)
    end
  end

  defp seed_default_agents do
    try do
      Synapsis.AgentConfigs.seed_defaults()
    rescue
      e in [RuntimeError, Ecto.QueryError, DBConnection.ConnectionError] ->
        Logger.warning("agent_config_seed_failed", error: Exception.message(e))
    end
  end

  defp seed_heartbeat_templates do
    maybe_apply(Synapsis.Agent.Heartbeat.Templates, :seed_defaults, [])
  rescue
    e in [RuntimeError, Ecto.QueryError, DBConnection.ConnectionError] ->
      Logger.warning("heartbeat_seed_failed", error: Exception.message(e))
  end

  defp sync_heartbeat_scheduler do
    maybe_apply(Synapsis.Agent.Heartbeat.Scheduler, :sync_crontab, [])
  rescue
    e in [RuntimeError, Ecto.QueryError, DBConnection.ConnectionError] ->
      Logger.warning("heartbeat_sync_failed", error: Exception.message(e))
  end

  defp register_env_providers do
    Enum.each(@env_provider_names, fn name ->
      api_key = Synapsis.Providers.env_api_key(name)

      base_url =
        Synapsis.Providers.env_base_url(name) || Synapsis.Providers.default_base_url(name)

      case {Synapsis.Provider.Registry.get(name), api_key} do
        {{:ok, _}, _} ->
          # Already registered from DB, skip
          :ok

        {_, nil} ->
          # No env var set, skip
          :ok

        {_, api_key} ->
          config =
            %{
              api_key: api_key,
              base_url: base_url,
              type: Synapsis.Providers.provider_type(name)
            }
            |> maybe_put(:default_model, Synapsis.Providers.env_default_model(name))

          Synapsis.Provider.Registry.register(name, config)
          Logger.info("env_provider_registered", provider: name)
      end
    end)
  end

  defp maybe_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
