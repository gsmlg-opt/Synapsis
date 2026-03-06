defmodule Synapsis.Agent.Runtime.Checkpoint do
  @moduledoc """
  Persisted runtime snapshot used for resumable graph execution.
  """

  alias Synapsis.Agent.Runtime.{Graph, Runner}

  @enforce_keys [:run_id, :graph, :node, :status, :state, :ctx, :updated_at]
  defstruct [:run_id, :graph, :node, :status, :state, :ctx, :error, :updated_at]

  @type t :: %__MODULE__{
          run_id: String.t(),
          graph: Graph.t(),
          node: atom() | :end | nil,
          status: Runner.status(),
          state: map(),
          ctx: map(),
          error: term() | nil,
          updated_at: DateTime.t()
        }
end
