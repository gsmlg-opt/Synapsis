defmodule SynapsisMcp.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Application.put_env(:synapsis_core, :skill_loader, &Synapsis.Backplane.SkillLoader.load/2)

    Application.put_env(:synapsis_core, :mcp_refresh, {Synapsis.MCP, :refresh_all, []})

    Application.put_env(:synapsis_provider, :provider_cleanup, &Synapsis.MCP.cleanup_provider/1)

    Application.put_env(
      :synapsis_provider,
      :credential_invalidation,
      &Synapsis.MCP.credentials_changed/1
    )

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
