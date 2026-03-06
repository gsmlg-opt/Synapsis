defmodule Synapsis.Agent.TestProjectBehaviour do
  @behaviour Synapsis.Agent.Behaviour

  alias Synapsis.Agent.WorkItem

  @impl true
  def init(project_id, opts) do
    {:ok, %{project_id: project_id, tag: Map.get(opts, :tag, "test")}}
  end

  @impl true
  def route(%WorkItem{} = work_item, state) do
    {:ok, %{node: :route, task: work_item.task_type, tag: state.tag}, state}
  end

  @impl true
  def execute(%WorkItem{} = work_item, route_plan, state) do
    {:ok, %{node: :execute, work_id: work_item.work_id, route_tag: route_plan.tag}, state}
  end

  @impl true
  def summarize(%WorkItem{} = work_item, execution_result, state) do
    {:ok,
     %{
       scope: :task,
       scope_id: work_item.work_id,
       kind: :task_result,
       content: "[#{state.tag}] #{execution_result.work_id}",
       metadata: %{custom: true, project_id: state.project_id}
     }, state}
  end
end
