defmodule Synapsis.Agent do
  @moduledoc """
  Public API for agent lifecycle, work dispatch, and memory access.
  """

  alias Synapsis.Agent.Memory.{EventStore, SummaryStore}
  alias Synapsis.Agent.Runtime.{Checkpoint, CheckpointStore, Graph, Runner}
  alias Synapsis.Agent.{GlobalAssistant, WorkItem}

  @spec start_project(String.t(), map()) :: {:ok, pid()} | {:error, term()}
  def start_project(project_id, metadata \\ %{})
      when is_binary(project_id) and is_map(metadata) do
    GlobalAssistant.start_project(project_id, metadata)
  end

  @spec dispatch_work(map() | WorkItem.t()) :: :ok | {:error, term()}
  def dispatch_work(attrs_or_work_item) do
    with {:ok, work_item} <- WorkItem.new(attrs_or_work_item) do
      GlobalAssistant.dispatch_work(work_item)
    end
  end

  @spec list_projects() :: [map()]
  def list_projects do
    GlobalAssistant.list_projects()
  end

  @spec project_status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def project_status(project_id) when is_binary(project_id) do
    GlobalAssistant.project_status(project_id)
  end

  @spec append_event(map()) :: :ok | {:error, term()}
  def append_event(attrs) when is_map(attrs), do: EventStore.append(attrs)

  @spec list_events(keyword()) :: [Synapsis.Agent.Memory.Event.t()]
  def list_events(filters \\ []), do: EventStore.list(filters)

  @spec put_summary(map()) :: :ok | {:error, term()}
  def put_summary(attrs) when is_map(attrs), do: SummaryStore.put(attrs)

  @spec get_summary(atom(), String.t(), atom()) ::
          {:ok, Synapsis.Agent.Memory.Summary.t()} | {:error, :not_found}
  def get_summary(scope, scope_id, kind)
      when is_atom(scope) and is_binary(scope_id) and is_atom(kind) do
    SummaryStore.get(scope, scope_id, kind)
  end

  @spec run_graph(Graph.t() | map(), map(), keyword()) ::
          {:ok, Runner.snapshot()} | {:error, term(), Runner.snapshot() | nil}
  def run_graph(graph, state \\ %{}, opts \\ []) when is_map(state) and is_list(opts) do
    Runner.run(graph, state, opts)
  end

  @spec start_runner(keyword()) :: GenServer.on_start()
  def start_runner(opts) when is_list(opts) do
    Runner.start_link(opts)
  end

  @spec resume_run(String.t(), map()) :: :ok | {:error, term()}
  def resume_run(run_id, ctx_updates \\ %{}) when is_binary(run_id) and is_map(ctx_updates) do
    Runner.resume(run_id, ctx_updates)
  end

  @spec await_run(String.t(), timeout()) :: Runner.snapshot() | {:error, term()}
  def await_run(run_id, timeout \\ 5_000) when is_binary(run_id) do
    Runner.await(run_id, timeout)
  end

  @spec run_snapshot(String.t()) :: Runner.snapshot() | {:error, term()}
  def run_snapshot(run_id) when is_binary(run_id) do
    Runner.snapshot(run_id)
  end

  @spec restore_run(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def restore_run(run_id, opts \\ []) when is_binary(run_id) and is_list(opts) do
    Runner.start_from_checkpoint(run_id, opts)
  end

  @spec get_checkpoint(String.t()) :: {:ok, Checkpoint.t()} | {:error, :not_found}
  def get_checkpoint(run_id) when is_binary(run_id) do
    CheckpointStore.get(run_id)
  end

  @spec list_checkpoints(keyword()) :: [Checkpoint.t()]
  def list_checkpoints(filters \\ []) do
    CheckpointStore.list(filters)
  end
end
