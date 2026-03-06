defmodule Synapsis.Agent.Memory.Event do
  @moduledoc """
  Immutable event entry for append-only agent memory.
  """

  @enforce_keys [:id, :event_type, :timestamp]
  defstruct [:id, :event_type, :timestamp, :project_id, :work_id, :payload]

  @type t :: %__MODULE__{
          id: String.t(),
          event_type: atom(),
          timestamp: DateTime.t(),
          project_id: String.t() | nil,
          work_id: String.t() | nil,
          payload: map()
        }
end
