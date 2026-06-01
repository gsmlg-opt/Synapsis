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

  @doc "Registry name for a session's per-session Task.Supervisor."
  def task_supervisor_via(session_id) do
    {:via, Registry, {Synapsis.Session.TaskSupervisorRegistry, session_id}}
  end

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    children = [
      # Task.Supervisor started first so it survives a Worker-only crash (rest_for_one).
      # I/O tasks (stream coordination, tool dispatch) run here; surviving tasks are
      # epoch-fenced by the Worker so stale results are dropped after restart.
      {Task.Supervisor, name: task_supervisor_via(session_id)},
      {Synapsis.Session.Worker, session_id: session_id}
    ]

    # Bound restarts (ADR-006 B1 poison protection): if the Worker's init/
    # rehydrate keeps crashing, exhaust the budget and let this tree terminate
    # rather than restart-loop. DynamicSupervisor starts us :temporary, and the
    # Worker records boot failures so the session is quarantined.
    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 3, max_seconds: 5)
  end
end
