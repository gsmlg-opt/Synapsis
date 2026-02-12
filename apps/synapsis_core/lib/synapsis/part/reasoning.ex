defmodule Synapsis.Part.Reasoning do
  @moduledoc "Reasoning/thinking content part."
  defstruct [:content]

  @type t :: %__MODULE__{content: String.t()}
end
