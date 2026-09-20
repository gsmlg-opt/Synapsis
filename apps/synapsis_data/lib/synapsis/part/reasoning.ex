defmodule Synapsis.Part.Reasoning do
  @moduledoc "Reasoning/thinking content part."
  defstruct [:content, :signature, provider_states: []]

  @type t :: %__MODULE__{
          content: String.t(),
          signature: String.t() | nil,
          provider_states: [map()]
        }
end
