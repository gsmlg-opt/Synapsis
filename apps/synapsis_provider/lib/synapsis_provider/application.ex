defmodule SynapsisProvider.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: Synapsis.Provider.TaskSupervisor},
      Synapsis.Provider.Registry
    ]

    opts = [strategy: :one_for_one, name: SynapsisProvider.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
