defmodule SynapsisData.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Synapsis.Repo
    ]

    opts = [strategy: :one_for_one, name: SynapsisData.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
