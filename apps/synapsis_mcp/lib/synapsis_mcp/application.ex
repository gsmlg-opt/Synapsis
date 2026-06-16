defmodule SynapsisMcp.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [Synapsis.MCP.Supervisor]
    opts = [strategy: :one_for_one, name: SynapsisMcp.RootSupervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Synapsis.MCP.start_enabled()
        {:ok, pid}

      other ->
        other
    end
  end
end
