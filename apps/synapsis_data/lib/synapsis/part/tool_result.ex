defmodule Synapsis.Part.ToolResult do
  @moduledoc "Tool execution result part."
  defstruct [:tool_use_id, :content, is_error: false]

  @type t :: %__MODULE__{
          tool_use_id: String.t(),
          content: String.t(),
          is_error: boolean()
        }
end
