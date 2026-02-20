defmodule Synapsis.Part.Image do
  @moduledoc "Image content part for multimodal LLM input."
  defstruct [:media_type, :data, :path]

  @type t :: %__MODULE__{
          media_type: String.t(),
          data: String.t(),
          path: String.t() | nil
        }
end
