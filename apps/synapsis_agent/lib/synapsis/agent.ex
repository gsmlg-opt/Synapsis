defmodule Synapsis.Agent do
  @moduledoc """
  Public API for agent lifecycle, work dispatch, and memory access.
  """

  alias Synapsis.Agent.Memory.{EventStore, SummaryStore}
  alias Synapsis.Agent.Runtime.{Engine, Graph, Runner}

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

  @doc """
  Run a graph synchronously to completion or first wait.
  Convenience wrapper for scripts and tests. For live sessions use `Session.Worker`.
  """
  @spec run_graph(Graph.t() | map(), map(), keyword()) ::
          {:ok, Runner.snapshot()} | {:error, term(), Runner.snapshot() | nil}
  def run_graph(graph, state \\ %{}, opts \\ []) when is_map(state) and is_list(opts) do
    Runner.run(graph, state, opts)
  end

  @doc "Step a graph until it waits or finishes. Pure — no process."
  @spec step_graph(Graph.t(), atom(), map(), map()) :: Engine.run_result()
  def step_graph(%Graph{} = graph, node, workflow_state \\ %{}, ctx \\ %{}) do
    Engine.run_until_wait(graph, node, workflow_state, ctx)
  end
end
