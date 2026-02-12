defmodule Synapsis.Part.ToolUse do
  @moduledoc "Tool use request part."
  defstruct [:tool, :tool_use_id, input: %{}, status: :pending]

  @type t :: %__MODULE__{
          tool: String.t(),
          tool_use_id: String.t(),
          input: map(),
          status: :pending | :approved | :denied | :completed | :error
        }
end
