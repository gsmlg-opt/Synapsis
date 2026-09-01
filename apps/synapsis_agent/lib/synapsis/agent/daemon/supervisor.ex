defmodule Synapsis.Agent.Daemon.Supervisor do
  @moduledoc false

  use Supervisor

  alias Synapsis.Agent.Daemon
  alias Synapsis.Agent.Daemon.StatusPublisher

  @task_supervisor Synapsis.Agent.Daemon.RunTaskSupervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    task_supervisor = Keyword.get(opts, :task_supervisor, @task_supervisor)
    status_publisher = Keyword.get(opts, :status_publisher, StatusPublisher)

    daemon_opts =
      opts
      |> Keyword.get(:daemon_opts, [])
      |> Keyword.put_new(:task_supervisor, task_supervisor)
      |> Keyword.put_new(:status_publisher, status_publisher)

    status_opts = [
      name: status_publisher,
      task_supervisor: task_supervisor,
      run_events: Keyword.get(daemon_opts, :run_events, Synapsis.Agent.RunEvents),
      event_timeout: Keyword.get(daemon_opts, :event_timeout, 1_000),
      retry_ms: Keyword.get(opts, :status_retry_ms, 50)
    ]

    children = [
      {Task.Supervisor, name: task_supervisor},
      {StatusPublisher, status_opts},
      Supervisor.child_spec({Daemon, daemon_opts}, id: Daemon)
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
