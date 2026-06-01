defmodule SynapsisCore.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    optional_children =
      [SynapsisPlugin.Supervisor]
      |> Enum.filter(&Code.ensure_loaded?/1)

    children =
      [
        # ADR-006 C4: Synapsis.Repo removed; storage is Concord + files + memory port.
        {Phoenix.PubSub, name: Synapsis.PubSub},
        {Task.Supervisor, name: Synapsis.Provider.TaskSupervisor},
        Synapsis.Provider.Registry,
        {Task.Supervisor, name: Synapsis.Tool.TaskSupervisor},
        Synapsis.Tool.Registry,
        {Registry, keys: :unique, name: Synapsis.FileWatcher.Registry},
        Synapsis.Session.Quarantine,
        # Config.Store now boots in SynapsisData.Application (data/storage layer)
        # so lower apps (e.g. synapsis_provider) can read configs without
        # depending upward on synapsis_core.
        Synapsis.Memory.Supervisor
      ] ++
        maybe_child(Synapsis.Workspace.GC) ++
        maybe_child(Synapsis.Agent.Heartbeat.LocalScheduler) ++
        optional_children

    opts = [strategy: :one_for_one, name: SynapsisCore.Supervisor]
    result = Supervisor.start_link(children, opts)

    case result do
      {:ok, _pid} ->
        ensure_session_store_ready()

        try do
          Synapsis.Providers.load_all_into_registry()
        rescue
          e in [RuntimeError, Ecto.QueryError, DBConnection.ConnectionError] ->
            Logger.warning("provider_registry_load_failed", error: Exception.message(e))
        end

        register_env_providers()
        seed_default_agents()
        seed_heartbeat_templates()

        maybe_apply(SynapsisPlugin.Loader, :start_auto_plugins, [])

        result

      other ->
        other
    end
  end

  @env_provider_names ~w(anthropic openai openai-sub google moonshot-ai moonshot-cn zhipu-ai zhipu-cn zhipu-coding minimax-io minimax-cn openrouter)

  # Bring up the embedded node-local Concord store once at boot (ADR-006 B1):
  # start the :ra default system and ensure Concord has formed its single-member
  # cluster before any session snapshots/rehydrates. See Session.Store.
  defp ensure_session_store_ready do
    case Synapsis.Session.Store.ensure_started() do
      :ok -> :ok
      {:error, reason} -> Logger.warning("session_store_not_ready", reason: inspect(reason))
    end
  rescue
    e -> Logger.warning("session_store_start_failed", error: Exception.message(e))
  end

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

  defp register_env_providers do
    Enum.each(@env_provider_names, fn name ->
      api_key = Synapsis.Providers.env_api_key(name)

      base_url =
        Synapsis.Providers.env_base_url(name) || Synapsis.Providers.default_base_url(name)

      case {Synapsis.Provider.Registry.get(name), api_key} do
        {{:ok, _}, _} ->
          :ok

        {_, nil} ->
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
