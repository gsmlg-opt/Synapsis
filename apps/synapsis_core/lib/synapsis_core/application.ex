defmodule SynapsisCore.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    optional_children =
      [SynapsisPlugin.Supervisor, SynapsisServer.Supervisor]
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
          e -> Logger.warning("provider_registry_load_failed", error: Exception.message(e))
        end

        register_env_providers()
        seed_default_agents()

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
      e -> Logger.warning("agent_config_seed_failed", error: Exception.message(e))
    end
  end

  defp register_env_providers do
    Enum.each(@env_provider_names, fn name ->
      env_var = Synapsis.Providers.env_var_name(name)
      base_url = Synapsis.Providers.default_base_url(name)

      case {Synapsis.Provider.Registry.get(name), System.get_env(env_var)} do
        {{:ok, _}, _} ->
          # Already registered from DB, skip
          :ok

        {_, nil} ->
          # No env var set, skip
          :ok

        {_, api_key} ->
          config = %{api_key: api_key, base_url: base_url, type: name}
          Synapsis.Provider.Registry.register(name, config)
          Logger.info("env_provider_registered", provider: name)
      end
    end)
  end
end
