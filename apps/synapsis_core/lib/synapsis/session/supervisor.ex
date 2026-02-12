defmodule Synapsis.Session.Supervisor do
  @moduledoc "Supervisor for a single session's process tree."
  use Supervisor

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    Supervisor.start_link(__MODULE__, opts, name: via(session_id))
  end

  defp via(session_id) do
    {:via, Registry, {Synapsis.Session.SupervisorRegistry, session_id}}
  end

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    children = [
      {Synapsis.Session.Worker, session_id: session_id}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
