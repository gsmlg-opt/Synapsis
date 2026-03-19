defmodule SynapsisServer.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    # synapsis_server owns the :phoenix dep but has no OTP application of its own
    # (single-app rule), so we must ensure :phoenix is started before the endpoint.
    Application.ensure_all_started(:phoenix)

    children = [
      SynapsisServer.Telemetry,
      {DNSCluster, query: Application.get_env(:synapsis_server, :dns_cluster_query) || :ignore},
      SynapsisServer.Endpoint
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
