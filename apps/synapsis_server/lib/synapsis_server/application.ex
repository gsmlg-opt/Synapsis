defmodule SynapsisServer.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SynapsisServer.Supervisor
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: SynapsisServer.ApplicationSupervisor
    )
  end
end
