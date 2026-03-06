defmodule Synapsis.AgentTest do
  use Synapsis.Agent.DataCase, async: false

  alias Synapsis.Agent

  setup do
    # Agent.Supervisor is already started by SynapsisCore.Application
    # Just ensure it's running
    case Process.whereis(Synapsis.Agent.Supervisor) do
      nil -> start_supervised!(Synapsis.Agent.Supervisor)
      _pid -> :ok
    end

    :ok
  end

  test "starts project and reports status" do
    project_id = "project-default-#{System.unique_integer([:positive])}"
    assert {:ok, pid} = Agent.start_project(project_id, %{path: "/tmp/project-a"})
    assert is_pid(pid)

    assert {:ok, status} = Agent.project_status(project_id)
    assert status.project_id == project_id
    assert status.status in [:idle, :busy]
    assert status.queue_length >= 0
    assert status.behaviour == Synapsis.Agent.Behaviours.DefaultProject
  end

  test "dispatches work via behaviour graph and appends lifecycle events" do
    project_id = "project-graph-#{System.unique_integer([:positive])}"

    assert {:ok, _pid} =
             Agent.start_project(project_id, %{
               behaviour: Synapsis.Agent.TestProjectBehaviour,
               behaviour_opts: %{tag: "graph"}
             })

    assert :ok =
             Agent.dispatch_work(%{
               work_id: "work-#{System.unique_integer([:positive])}",
               project_id: project_id,
               task_type: :command_execution,
               payload: %{command: "mix test"},
               origin: :user
             })

    work_id =
      Agent.list_events(project_id: project_id)
      |> Enum.find(&(&1.event_type == :task_received))
      |> then(& &1.work_id)

    assert_event(project_id, :task_received, work_id)
    assert_event(project_id, :routing_decision, work_id)
    assert_event(project_id, :task_completed, work_id)

    assert {:ok, summary} = Agent.get_summary(:task, work_id, :task_result)
    assert summary.content =~ "[graph]"
  end

  test "writes and reads summaries" do
    scope_id = "project-#{System.unique_integer([:positive])}"

    assert :ok =
             Agent.put_summary(%{
               scope: :project,
               scope_id: scope_id,
               kind: :daily,
               content: "Executed 3 tasks with zero failures",
               metadata: %{tools: ["bash", "grep"]}
             })

    assert {:ok, summary} = Agent.get_summary(:project, scope_id, :daily)
    assert summary.content =~ "Executed 3 tasks"
    assert summary.metadata["tools"] == ["bash", "grep"]
  end

  defp assert_event(project_id, event_type, work_id) do
    assert eventually(fn ->
             Agent.list_events(project_id: project_id, work_id: work_id)
             |> Enum.any?(&(&1.event_type == event_type))
           end)
  end

  defp eventually(fun, retries \\ 20)

  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, retries) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, retries - 1)
    end
  end
end
