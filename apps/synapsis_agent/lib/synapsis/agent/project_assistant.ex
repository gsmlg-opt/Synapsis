defmodule Synapsis.Agent.ProjectAssistant do
  @moduledoc """
  Per-project assistant that serializes work and runs a behavior graph.
  """

  use GenServer

  alias Synapsis.Agent.Memory.EventStore
  alias Synapsis.Agent.Runtime.ProjectGraph
  alias Synapsis.Agent.WorkItem

  @type state :: %{
          project_id: String.t(),
          behaviour: module(),
          behaviour_state: term(),
          queue: :queue.queue(WorkItem.t()),
          current_work: WorkItem.t() | nil,
          provider: term(),
          tool_dispatcher: term()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    project_id = Keyword.fetch!(opts, :project_id)
    GenServer.start_link(__MODULE__, opts, name: via(project_id))
  end

  @spec enqueue(pid(), WorkItem.t()) :: :ok
  def enqueue(pid, %WorkItem{} = work_item), do: GenServer.call(pid, {:enqueue, work_item})

  @spec update_provider(pid(), term()) :: :ok
  def update_provider(pid, provider), do: GenServer.call(pid, {:update_provider, provider})

  @spec status(pid()) :: {:ok, map()} | {:error, term()}
  def status(pid), do: GenServer.call(pid, :status)

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    project_id = Keyword.fetch!(opts, :project_id)

    %{
      id: {__MODULE__, project_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker
    }
  end

  @impl true
  def init(opts) do
    project_id = Keyword.fetch!(opts, :project_id)
    behaviour = Keyword.get(opts, :behaviour, Synapsis.Agent.Behaviours.DefaultProject)
    behaviour_opts = Keyword.get(opts, :behaviour_opts, %{})

    provider = Keyword.get(opts, :provider)
    tool_dispatcher = Keyword.get(opts, :tool_dispatcher)

    with {:module, _} <- Code.ensure_loaded(behaviour),
         true <- function_exported?(behaviour, :init, 2),
         {:ok, behaviour_state} <- behaviour.init(project_id, behaviour_opts) do
      {:ok,
       %{
         project_id: project_id,
         behaviour: behaviour,
         behaviour_state: behaviour_state,
         queue: :queue.new(),
         current_work: nil,
         provider: provider,
         tool_dispatcher: tool_dispatcher
       }}
    else
      _ -> {:stop, {:invalid_behaviour, behaviour}}
    end
  end

  @impl true
  def handle_call({:enqueue, work_item}, _from, state) do
    queue = :queue.in(work_item, state.queue)
    next_state = maybe_start_next(%{state | queue: queue})
    {:reply, :ok, next_state}
  end

  def handle_call({:update_provider, provider}, _from, state) do
    {:reply, :ok, %{state | provider: provider}}
  end

  def handle_call(:status, _from, state) do
    status = if state.current_work, do: :busy, else: :idle
    queue_length = :queue.len(state.queue)

    payload = %{
      status: status,
      queue_length: queue_length,
      current_work_id: if(state.current_work, do: state.current_work.work_id, else: nil),
      behaviour: state.behaviour,
      recent_activity_at: DateTime.utc_now()
    }

    {:reply, {:ok, payload}, state}
  end

  @impl true
  def handle_info({:execute, work_item}, state) do
    {next_state, outcome} = run_graph(work_item, state)

    EventStore.append(%{
      event_type: :task_completed,
      project_id: state.project_id,
      work_id: work_item.work_id,
      payload: outcome
    })

    {:noreply, next_state |> Map.put(:current_work, nil) |> maybe_start_next()}
  end

  defp run_graph(work_item, state) do
    case ProjectGraph.run(work_item, state.behaviour, state.behaviour_state) do
      {:ok, snapshot} ->
        runtime_state = snapshot.state
        maybe_append_routing_decision(state.project_id, work_item.work_id, runtime_state)

        next_behaviour_state = Map.get(runtime_state, :behaviour_state, state.behaviour_state)
        outcome = Map.get(runtime_state, :outcome, %{status: :error, reason: :missing_outcome})

        {put_in(state.behaviour_state, next_behaviour_state), outcome}

      {:error, reason, nil} ->
        {state, %{status: :error, reason: reason}}

      {:error, reason, snapshot} ->
        next_behaviour_state =
          get_in(snapshot, [:state, :behaviour_state]) || state.behaviour_state

        {put_in(state.behaviour_state, next_behaviour_state), %{status: :error, reason: reason}}
    end
  end

  defp maybe_append_routing_decision(project_id, work_id, %{route_plan: route_plan}) do
    EventStore.append(%{
      event_type: :routing_decision,
      project_id: project_id,
      work_id: work_id,
      payload: route_plan
    })
  end

  defp maybe_append_routing_decision(_project_id, _work_id, _runtime_state), do: :ok

  defp maybe_start_next(%{current_work: %WorkItem{}} = state), do: state

  defp maybe_start_next(state) do
    case :queue.out(state.queue) do
      {{:value, work_item}, queue} ->
        Process.send_after(self(), {:execute, work_item}, 0)
        %{state | queue: queue, current_work: work_item}

      {:empty, _queue} ->
        state
    end
  end

  defp via(project_id), do: {:via, Registry, {Synapsis.Agent.ProjectRegistry, project_id}}
end
