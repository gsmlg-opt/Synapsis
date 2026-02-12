defmodule Synapsis.Part.Snapshot do
  @moduledoc "File snapshot part."
  defstruct files: []

  @type t :: %__MODULE__{files: [map()]}
end
