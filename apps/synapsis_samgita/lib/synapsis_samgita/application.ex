defmodule SynapsisSamgita.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: SynapsisSamgita.AttemptRegistry},
      {DynamicSupervisor, name: SynapsisSamgita.AttemptSupervisor, strategy: :one_for_one},
      SynapsisSamgita.Connection
    ]
    opts = [strategy: :one_for_one, name: SynapsisSamgita.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
