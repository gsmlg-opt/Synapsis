defmodule SynapsisMcp.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [Synapsis.MCP.Supervisor]
    opts = [strategy: :one_for_one, name: SynapsisMcp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
