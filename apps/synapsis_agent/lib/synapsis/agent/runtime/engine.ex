defmodule Synapsis.Agent.Runtime.Engine do
  @moduledoc """
  Pure graph execution engine — no process, no state.

  Replaces the Runner GenServer for in-process use.
  `run_until_wait/4` steps the graph until a node returns `{:wait, _}` or the
  graph reaches `:end`. Node crashes propagate up to the caller (let it crash).
  """

  alias Synapsis.Agent.Runtime.Graph

  @type node_name :: atom() | :end
  @type workflow_state :: map()
  @type ctx :: map()

  @type run_result ::
          {:waiting, node_name(), workflow_state()}
          | {:done, workflow_state()}
          | {:error, term(), workflow_state()}

  @doc """
  Step through the graph starting at `node` until the engine parks (`{:wait}`)
  or finishes (`{:end}`). Returns the node at which it parked and the updated
  workflow state.
  """
  @spec run_until_wait(Graph.t(), node_name(), workflow_state(), ctx()) :: run_result()
  def run_until_wait(graph, node, workflow_state, ctx) do
    case step(graph, node, workflow_state, ctx) do
      {:next, :end, new_state} ->
        {:done, new_state}

      {:next, next_node, new_state} ->
        run_until_wait(graph, next_node, new_state, ctx)

      {:wait, new_state} ->
        {:waiting, node, new_state}

      {:error, reason, new_state} ->
        {:error, reason, new_state}
    end
  end

  @doc """
  Execute a single node and resolve the next destination.
  Does NOT recurse — use `run_until_wait/4` for a full step loop.
  """
  @spec step(Graph.t(), node_name(), workflow_state(), ctx()) ::
          {:next, node_name(), workflow_state()}
          | {:wait, workflow_state()}
          | {:error, term(), workflow_state()}
  def step(_graph, :end, workflow_state, _ctx), do: {:next, :end, workflow_state}

  def step(graph, node, workflow_state, ctx) do
    case Graph.fetch_node(graph, node) do
      {:ok, module} ->
        case invoke(module, workflow_state, ctx) do
          {:node_error, reason, new_state} ->
            {:error, reason, new_state}

          {:next, selector, new_state} ->
            case Graph.resolve_next(graph, node, selector) do
              {:ok, next} ->
                {:next, next, new_state}

              {:error, reason} ->
                {:error, {:invalid_transition, node, selector, reason}, new_state}
            end

          {:end, new_state} ->
            {:next, :end, new_state}

          {:wait, new_state} ->
            {:wait, new_state}

          other ->
            {:error, {:invalid_node_result, module, other}, workflow_state}
        end

      {:error, reason} ->
        {:error, {:unknown_node, node, reason}, workflow_state}
    end
  end

  # Node crashes are caught and returned as {:error, ...} so the session can
  # surface them to the user rather than silently crashing the Worker.
  # Uses a private {:node_error, ...} sentinel to distinguish caught node crashes
  # from valid node return values like {:next, ...} or {:wait, ...}.
  defp invoke(module, workflow_state, ctx) do
    try do
      module.run(workflow_state, ctx)
    rescue
      exception ->
        {:node_error, {:node_crash, module, exception, __STACKTRACE__}, workflow_state}
    catch
      kind, reason ->
        {:node_error, {:node_throw, module, kind, reason, __STACKTRACE__}, workflow_state}
    end
  end
end
