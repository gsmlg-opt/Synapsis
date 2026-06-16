defmodule Synapsis.MCP.Supervisor do
  @moduledoc "Top-level supervisor: Registry + DynamicSupervisor for MCP servers."
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Registry, keys: :unique, name: Synapsis.MCP.Registry},
      {DynamicSupervisor, name: Synapsis.MCP.DynamicSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
