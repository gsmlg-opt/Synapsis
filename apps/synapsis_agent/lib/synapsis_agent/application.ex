defmodule SynapsisAgent.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Synapsis.Session.Registry},
      {Registry, keys: :unique, name: Synapsis.Session.SupervisorRegistry},
      {Registry, keys: :unique, name: Synapsis.Session.TaskSupervisorRegistry},
      {Registry, keys: :unique, name: Synapsis.Agent.Registry},
      Synapsis.Session.DynamicSupervisor,
      {Registry, keys: :unique, name: Synapsis.Voice.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Synapsis.Voice.Supervisor},
      Synapsis.Agent.Supervisor
    ]

    opts = [strategy: :rest_for_one, name: SynapsisAgent.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
