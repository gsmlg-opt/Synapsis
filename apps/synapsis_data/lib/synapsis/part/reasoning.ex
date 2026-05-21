defmodule Synapsis.Part.Reasoning do
  @moduledoc "Reasoning/thinking content part."
  defstruct [:content, :signature]

  @type t :: %__MODULE__{content: String.t(), signature: String.t() | nil}
end
