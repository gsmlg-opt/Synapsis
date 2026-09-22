defmodule SynapsisMcp.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Application.put_env(:synapsis_core, :skill_loader, &Synapsis.Backplane.SkillLoader.load/2)

    children = [Synapsis.MCP.Supervisor, Synapsis.Backplane.StartupRefresh]
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
