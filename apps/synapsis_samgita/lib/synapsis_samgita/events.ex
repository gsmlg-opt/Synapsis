defmodule SynapsisSamgita.Events do
  @moduledoc "PubSub topics for Samgita integration state shown in the UI."

  @inbox_topic "samgita:inbox"
  @status_topic "samgita:status"
  @attempts_topic "samgita:attempts"

  def subscribe, do: Phoenix.PubSub.subscribe(Synapsis.PubSub, @inbox_topic)
  def subscribe_status, do: Phoenix.PubSub.subscribe(Synapsis.PubSub, @status_topic)
  def subscribe_attempts, do: Phoenix.PubSub.subscribe(Synapsis.PubSub, @attempts_topic)

  def broadcast_inbox_changed(event_id),
    do: Phoenix.PubSub.broadcast(Synapsis.PubSub, @inbox_topic, {:samgita_inbox_changed, event_id})

  def broadcast_status(status),
    do: Phoenix.PubSub.broadcast(Synapsis.PubSub, @status_topic, {:samgita_status, status})

  def broadcast_attempt(view),
    do: Phoenix.PubSub.broadcast(Synapsis.PubSub, @attempts_topic, {:samgita_attempt, view})
end
