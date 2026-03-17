defmodule Synapsis.Agent.Messaging do
  @moduledoc """
  Agent-to-agent messaging via PubSub typed envelopes.
  Provides structured communication between GlobalAssistant,
  ProjectAssistant, and coding sessions.
  """

  @type agent_id :: String.t()

  @type envelope :: %{
          from: agent_id(),
          to: agent_id(),
          ref: String.t(),
          type: :user_message | :agent_message | :delegation | :notification | :completion,
          payload: term(),
          timestamp: DateTime.t()
        }

  @doc "Build and send an envelope via PubSub."
  @spec send_envelope(envelope()) :: :ok
  def send_envelope(%{to: to} = envelope) do
    envelope = Map.put_new(envelope, :timestamp, DateTime.utc_now())
    envelope = Map.put_new(envelope, :ref, Ecto.UUID.generate())

    Phoenix.PubSub.broadcast(
      Synapsis.PubSub,
      "agent:#{to}",
      {:agent_envelope, envelope}
    )
  end

  @doc "Subscribe to messages for a given agent."
  @spec subscribe(agent_id()) :: :ok | {:error, term()}
  def subscribe(agent_id) do
    Phoenix.PubSub.subscribe(Synapsis.PubSub, "agent:#{agent_id}")
  end

  @doc "Build an envelope."
  @spec envelope(agent_id(), agent_id(), atom(), term()) :: envelope()
  def envelope(from, to, type, payload) do
    %{
      from: from,
      to: to,
      ref: Ecto.UUID.generate(),
      type: type,
      payload: payload,
      timestamp: DateTime.utc_now()
    }
  end

  @doc "Build a delegation envelope."
  @spec delegate(agent_id(), agent_id(), term()) :: envelope()
  def delegate(from, to, payload) do
    envelope(from, to, :delegation, payload)
  end

  @doc "Build a completion envelope."
  @spec complete(agent_id(), agent_id(), String.t(), term()) :: envelope()
  def complete(from, to, ref, payload) do
    %{
      from: from,
      to: to,
      ref: ref,
      type: :completion,
      payload: payload,
      timestamp: DateTime.utc_now()
    }
  end
end
