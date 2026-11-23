defmodule Synapsis.Part.SpokenAudio do
  @moduledoc "Generated speech transcript with links to the device playback record."
  @enforce_keys [:item_id, :response_id, :content_index, :connection_generation, :text]
  defstruct @enforce_keys

  def from_map(map) do
    attrs =
      Map.new(@enforce_keys, fn key ->
        {key, Map.get(map, key, Map.get(map, Atom.to_string(key)))}
      end)

    struct!(__MODULE__, attrs)
  end
end
