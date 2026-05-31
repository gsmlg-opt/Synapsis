defmodule Synapsis.Agent.Runtime.Runner do
  @moduledoc """
  Synchronous graph execution helper — no process.

  `run/3` is a convenience wrapper around `Engine.run_until_wait/4` for
  one-shot synchronous runs (tests, scripts). It steps the graph to completion
  (or first `:wait`) and returns a snapshot map.

  The GenServer-based Runner has been removed in favour of the per-session
  `Session.Worker` owning the engine inline. See ADR-006.
  """

  alias Synapsis.Agent.Runtime.{Engine, Graph}

  @type status :: :completed | :waiting | :failed
  @type snapshot :: %{
          run_id: String.t(),
          status: status(),
          node: atom() | :end | nil,
          state: map(),
          ctx: map(),
          error: term() | nil
        }

  @spec run(Graph.t() | map(), map(), keyword()) ::
          {:ok, snapshot()} | {:error, term(), snapshot() | nil}
  def run(graph, workflow_state \\ %{}, opts \\ [])
      when is_map(workflow_state) and is_list(opts) do
    run_id = Keyword.get_lazy(opts, :run_id, &default_run_id/0)
    ctx = Keyword.get(opts, :ctx, %{})

    with {:ok, g} <- Graph.new(graph) do
      case Engine.run_until_wait(g, g.start, workflow_state, ctx) do
        {:done, final_state} ->
          {:ok, snap(run_id, :completed, :end, final_state, ctx, nil)}

        {:waiting, node, parked_state} ->
          {:ok, snap(run_id, :waiting, node, parked_state, ctx, nil)}

        {:error, reason, final_state} ->
          snap = snap(run_id, :failed, nil, final_state, ctx, reason)
          {:error, reason, snap}
      end
    else
      {:error, reason} -> {:error, reason, nil}
    end
  end

  defp snap(run_id, status, node, state, ctx, error) do
    %{run_id: run_id, status: status, node: node, state: state, ctx: ctx, error: error}
  end

  defp default_run_id do
    "run-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end
end
