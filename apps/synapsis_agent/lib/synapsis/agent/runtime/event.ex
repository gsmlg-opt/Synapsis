defmodule Synapsis.Agent.Runtime.Event do
  @moduledoc """
  Runtime lifecycle event emitted by `Synapsis.Agent.Runtime.Runner`.
  """

  @type event_type ::
          :agent_started
          | :agent_waiting
          | :agent_resumed
          | :agent_finished
          | :agent_failed
          | :node_started
          | :node_finished

  @enforce_keys [:run_id, :type, :timestamp]
  defstruct [:run_id, :type, :timestamp, :node, :payload]

  @type t :: %__MODULE__{
          run_id: String.t(),
          type: event_type(),
          timestamp: DateTime.t(),
          node: atom() | :end | nil,
          payload: map()
        }
end
