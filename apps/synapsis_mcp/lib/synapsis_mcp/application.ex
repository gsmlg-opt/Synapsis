defmodule SynapsisMcp.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # NOTE: real children (Synapsis.MCP.Supervisor) wired in Task 9. Empty for now
    # so the umbrella boots while the MCP modules are being built.
    children = []
    opts = [strategy: :one_for_one, name: SynapsisMcp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
