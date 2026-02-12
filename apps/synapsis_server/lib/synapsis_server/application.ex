defmodule SynapsisServer.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SynapsisServerWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:synapsis_server, :dns_cluster_query) || :ignore},
      SynapsisServerWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: SynapsisServer.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    SynapsisServerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
