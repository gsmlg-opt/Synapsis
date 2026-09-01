defmodule Synapsis.Agent.Daemon.Supervisor do
  @moduledoc false

  use Supervisor

  alias Synapsis.Agent.Daemon

  @task_supervisor Synapsis.Agent.Daemon.RunTaskSupervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    task_supervisor = Keyword.get(opts, :task_supervisor, @task_supervisor)

    daemon_opts =
      opts
      |> Keyword.get(:daemon_opts, [])
      |> Keyword.put_new(:task_supervisor, task_supervisor)

    children = [
      {Task.Supervisor, name: task_supervisor},
      Supervisor.child_spec({Daemon, daemon_opts}, id: Daemon)
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
