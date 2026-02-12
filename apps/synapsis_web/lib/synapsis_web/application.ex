defmodule SynapsisWeb.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SynapsisWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:synapsis_web, :dns_cluster_query) || :ignore},
      SynapsisWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: SynapsisWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    SynapsisWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
