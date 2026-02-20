defmodule SynapsisCore.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      Synapsis.Repo,
      {Phoenix.PubSub, name: Synapsis.PubSub},
      {Task.Supervisor, name: Synapsis.Provider.TaskSupervisor},
      Synapsis.Provider.Registry,
      {Task.Supervisor, name: Synapsis.Tool.TaskSupervisor},
      Synapsis.Tool.Registry,
      {Registry, keys: :unique, name: Synapsis.Session.Registry},
      {Registry, keys: :unique, name: Synapsis.Session.SupervisorRegistry},
      {Registry, keys: :unique, name: Synapsis.FileWatcher.Registry},
      Synapsis.Session.DynamicSupervisor,
      SynapsisPlugin.Supervisor,
      SynapsisServer.Supervisor
    ]

    opts = [strategy: :one_for_one, name: SynapsisCore.Supervisor]
    result = Supervisor.start_link(children, opts)

    case result do
      {:ok, _pid} ->
        Synapsis.Tool.Builtin.register_all()

        try do
          Synapsis.Providers.load_all_into_registry()
        rescue
          e -> Logger.warning("provider_registry_load_failed", error: Exception.message(e))
        end

        try do
          apply(SynapsisPlugin.Loader, :start_auto_plugins, [])
        rescue
          e -> Logger.warning("plugin_auto_start_failed", error: Exception.message(e))
        end

        result

      other ->
        other
    end
  end
end
