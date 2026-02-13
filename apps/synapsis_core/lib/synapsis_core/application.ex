defmodule SynapsisCore.Application do
  @moduledoc false
  use Application

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
      {Registry, keys: :unique, name: Synapsis.MCP.Registry},
      {Registry, keys: :unique, name: Synapsis.FileWatcher.Registry},
      Synapsis.Session.DynamicSupervisor,
      Synapsis.MCP.Supervisor,
      SynapsisLsp.Supervisor,
      SynapsisWeb.Supervisor
    ]

    opts = [strategy: :one_for_one, name: SynapsisCore.Supervisor]
    result = Supervisor.start_link(children, opts)

    case result do
      {:ok, _pid} ->
        Synapsis.Tool.Builtin.register_all()

        try do
          Synapsis.Providers.load_all_into_registry()
        rescue
          _ -> :ok
        end

        result

      other ->
        other
    end
  end
end
