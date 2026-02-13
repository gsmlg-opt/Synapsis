defmodule SynapsisLsp.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {DynamicSupervisor, name: Synapsis.LSP.DynamicSupervisor, strategy: :one_for_one},
      {Registry, keys: :unique, name: Synapsis.LSP.Registry}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
