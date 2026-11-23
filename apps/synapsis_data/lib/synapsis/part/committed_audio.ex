defmodule Synapsis.Part.CommittedAudio do
  @moduledoc "A committed Realtime input item. Raw audio is not retained."
  @enforce_keys [:item_id, :connection_generation]
  defstruct [:item_id, :connection_generation]
end
