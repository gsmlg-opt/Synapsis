defmodule Synapsis.Part.Text do
  @moduledoc "Text content part."
  defstruct [:content]

  @type t :: %__MODULE__{content: String.t()}
end
