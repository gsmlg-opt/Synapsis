defmodule Synapsis.Part.ToolResult do
  @moduledoc """
  Tool execution result part.

  `content` remains the legacy text representation. `projection` optionally
  preserves versioned host result data for structured persistence and later
  presentation; this data layer does not interpret or execute that projection.
  """
  defstruct [:tool_use_id, :content, :projection, is_error: false]

  @type t :: %__MODULE__{
          tool_use_id: String.t(),
          content: String.t(),
          projection: map() | nil,
          is_error: boolean()
        }
end
