defmodule SynapsisAgent.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Synapsis.Session.Registry},
      {Registry, keys: :unique, name: Synapsis.Session.SupervisorRegistry},
      Synapsis.Session.DynamicSupervisor,
      Synapsis.Agent.Supervisor
    ]

    opts = [strategy: :rest_for_one, name: SynapsisAgent.Supervisor]
    result = Supervisor.start_link(children, opts)

    case result do
      {:ok, _pid} ->
        Synapsis.Tool.Builtin.register_all()
        maybe_apply(Synapsis.Workspace.Tools, :register_all, [])
        result

      other ->
        other
    end
  end

  defp maybe_apply(mod, fun, args) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, length(args)) do
      apply(mod, fun, args)
    end
  end
end
