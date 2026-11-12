defmodule SynapsisSamgita.Events do
  @moduledoc "PubSub topics for Samgita integration state shown in the UI."

  @inbox_topic "samgita:inbox"

  def subscribe, do: Phoenix.PubSub.subscribe(Synapsis.PubSub, @inbox_topic)

  def broadcast_inbox_changed(event_id) do
    Phoenix.PubSub.broadcast(Synapsis.PubSub, @inbox_topic, {:samgita_inbox_changed, event_id})
  end
end
