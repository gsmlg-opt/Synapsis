defmodule Synapsis.Agent.GlobalAssistant do
  @moduledoc """
  Control plane process that tracks projects and dispatches work.
  """

  use GenServer

  alias Synapsis.Agent.Memory.EventStore
  alias Synapsis.Agent.{ProjectAssistant, WorkItem}

  @name __MODULE__

  @type project_state :: %{
          project_id: String.t(),
          pid: pid(),
          status: atom(),
          current_work_id: String.t() | nil,
          queue_length: non_neg_integer(),
          recent_activity_at: DateTime.t(),
          metadata: map()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, @name))
  end

  @spec start_project(String.t(), map()) :: {:ok, pid()} | {:error, term()}
  def start_project(project_id, metadata \\ %{}) do
    GenServer.call(@name, {:start_project, project_id, metadata}, 10_000)
  end

  @spec dispatch_work(WorkItem.t()) :: :ok | {:error, term()}
  def dispatch_work(%WorkItem{} = work_item) do
    GenServer.call(@name, {:dispatch_work, work_item})
  end

  @spec list_projects() :: [project_state()]
  def list_projects do
    GenServer.call(@name, :list_projects)
  end

  @spec project_status(String.t()) :: {:ok, project_state()} | {:error, :not_found}
  def project_status(project_id) when is_binary(project_id) do
    GenServer.call(@name, {:project_status, project_id})
  end

  @impl true
  def init(:ok) do
    {:ok, %{projects: %{}}}
  end

  @impl true
  def handle_call({:start_project, project_id, metadata}, _from, state) do
    case ensure_project(project_id, metadata, state) do
      {:ok, project_state, next_state} -> {:reply, {:ok, project_state.pid}, next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:dispatch_work, work_item}, _from, state) do
    with {:ok, project_state, next_state} <- ensure_project(work_item.project_id, %{}, state),
         :ok <- ProjectAssistant.enqueue(project_state.pid, work_item) do
      EventStore.append(%{
        event_type: :task_received,
        project_id: work_item.project_id,
        work_id: work_item.work_id,
        payload: %{
          task_type: work_item.task_type,
          priority: work_item.priority,
          origin: work_item.origin
        }
      })

      updated =
        Map.put(next_state.projects, work_item.project_id, %{
          project_state
          | recent_activity_at: DateTime.utc_now()
        })

      {:reply, :ok, %{next_state | projects: updated}}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:list_projects, _from, state) do
    projects =
      state.projects
      |> Map.values()
      |> Enum.map(&sync_project_state/1)
      |> Enum.sort_by(& &1.project_id)

    {:reply, projects, %{state | projects: map_by_project_id(projects)}}
  end

  def handle_call({:project_status, project_id}, _from, state) do
    case Map.fetch(state.projects, project_id) do
      {:ok, project_state} ->
        synced = sync_project_state(project_state)
        {:reply, {:ok, synced}, put_in(state.projects[project_id], synced)}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  defp ensure_project(project_id, metadata, state) do
    case Map.fetch(state.projects, project_id) do
      {:ok, project_state} ->
        {:ok, sync_project_state(project_state), state}

      :error ->
        case DynamicSupervisor.start_child(
               Synapsis.Agent.ProjectSupervisor,
               {ProjectAssistant,
                project_id: project_id,
                behaviour:
                  metadata_value(metadata, :behaviour, Synapsis.Agent.Behaviours.DefaultProject),
                behaviour_opts: metadata_value(metadata, :behaviour_opts, %{}),
                provider: metadata_value(metadata, :provider, nil),
                tool_dispatcher: metadata_value(metadata, :tool_dispatcher, nil)}
             ) do
          {:ok, pid} ->
            project_state = %{
              project_id: project_id,
              pid: pid,
              status: :idle,
              current_work_id: nil,
              queue_length: 0,
              recent_activity_at: DateTime.utc_now(),
              metadata: metadata
            }

            EventStore.append(%{
              event_type: :project_started,
              project_id: project_id,
              payload: %{metadata: metadata}
            })

            {:ok, project_state, put_in(state.projects[project_id], project_state)}

          {:error, {:already_started, pid}} ->
            project_state = %{
              project_id: project_id,
              pid: pid,
              status: :idle,
              current_work_id: nil,
              queue_length: 0,
              recent_activity_at: DateTime.utc_now(),
              metadata: metadata
            }

            {:ok, project_state, put_in(state.projects[project_id], project_state)}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp sync_project_state(project_state) do
    case ProjectAssistant.status(project_state.pid) do
      {:ok, runtime} ->
        Map.merge(project_state, runtime)

      _ ->
        %{project_state | status: :down}
    end
  end

  defp map_by_project_id(projects) do
    Map.new(projects, fn project -> {project.project_id, project} end)
  end

  defp metadata_value(metadata, key, default) do
    Map.get(metadata, key, Map.get(metadata, Atom.to_string(key), default))
  end
end
