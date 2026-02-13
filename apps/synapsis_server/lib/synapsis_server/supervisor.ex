defmodule SynapsisServer.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      SynapsisServer.Telemetry,
      {DNSCluster, query: Application.get_env(:synapsis_server, :dns_cluster_query) || :ignore},
      SynapsisServer.Endpoint
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
