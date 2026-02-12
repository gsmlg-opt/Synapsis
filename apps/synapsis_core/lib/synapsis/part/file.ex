defmodule Synapsis.Part.File do
  @moduledoc "File content part."
  defstruct [:path, :content]

  @type t :: %__MODULE__{path: String.t(), content: String.t()}
end
