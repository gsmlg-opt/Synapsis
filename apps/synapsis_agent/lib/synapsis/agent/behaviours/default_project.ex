defmodule Synapsis.Agent.Behaviours.DefaultProject do
  @moduledoc """
  Default project behavior implementing a simple route/execute/summarize graph.
  """

  @behaviour Synapsis.Agent.Behaviour

  alias Synapsis.Agent.WorkItem

  @impl true
  def init(project_id, opts) do
    {:ok, %{project_id: project_id, opts: opts}}
  end

  @impl true
  def route(%WorkItem{} = work_item, state) do
    plan = %{
      workflow: Map.get(work_item.payload, :workflow, :default),
      task_type: work_item.task_type,
      constraints: work_item.constraints || %{}
    }

    {:ok, plan, state}
  end

  @impl true
  def execute(%WorkItem{} = work_item, route_plan, state) do
    result = %{
      status: :ok,
      task_type: work_item.task_type,
      workflow: route_plan.workflow
    }

    {:ok, result, state}
  end

  @impl true
  def summarize(%WorkItem{} = work_item, execution_result, state) do
    summary = %{
      scope: :task,
      scope_id: work_item.work_id,
      kind: :task_result,
      content: "Task #{work_item.work_id} finished with #{execution_result.status}",
      metadata: %{
        project_id: work_item.project_id,
        task_type: work_item.task_type,
        workflow: execution_result.workflow
      }
    }

    {:ok, summary, state}
  end
end
