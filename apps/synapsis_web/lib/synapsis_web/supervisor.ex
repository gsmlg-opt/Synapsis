defmodule SynapsisWeb.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      SynapsisWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:synapsis_web, :dns_cluster_query) || :ignore},
      SynapsisWeb.Endpoint
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
