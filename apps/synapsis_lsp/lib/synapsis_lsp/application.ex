defmodule SynapsisLsp.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {DynamicSupervisor, name: Synapsis.LSP.DynamicSupervisor, strategy: :one_for_one},
      {Registry, keys: :unique, name: Synapsis.LSP.Registry}
    ]

    opts = [strategy: :one_for_one, name: SynapsisLsp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
