defmodule Synapsis.Part.Agent do
  @moduledoc "Agent mode switch part."
  defstruct [:agent, :message]

  @type t :: %__MODULE__{agent: String.t(), message: String.t()}
end
