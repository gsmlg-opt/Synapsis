defmodule Synapsis.Session.Fork do
  @moduledoc "Fork a session at a given message, creating a new branch."

  alias Synapsis.{Message, Part, Session, Sessions}
  alias Synapsis.Session.Store

  @doc "Copy through `:at_message`, or stop before it with `include_message: false`."
  def fork(session_id, opts \\ []) do
    message_id = Keyword.get(opts, :at_message)
    include_message? = Keyword.get(opts, :include_message, true)

    with {:ok, session} <- Sessions.get(session_id),
         :ok <- forkable(session),
         {:ok, messages} <- prefix(session.messages, message_id, include_message?) do
      do_fork(session, messages)
    end
  end

  defp forkable(session) do
    if Sessions.host_voice?(session) or
         match?(%{kind: :host_voice}, Synapsis.AgentConfigs.get_by_name(session.agent)),
       do: {:error, :fixed_host_session},
       else: :ok
  end

  defp prefix(messages, nil, _include_message?), do: {:ok, messages}

  defp prefix(messages, message_id, include_message?) do
    case Enum.split_while(messages, &(&1.id != message_id)) do
      {_, []} -> {:error, :message_not_found}
      {prefix, [target | _]} when include_message? -> {:ok, prefix ++ [target]}
      {prefix, [_target | _]} -> {:ok, prefix}
    end
  end

  defp do_fork(session, messages) do
    now = DateTime.utc_now()

    new_session = %Session{
      id: Ecto.UUID.generate(),
      provider: session.provider,
      model: session.model,
      agent: session.agent,
      title: "Fork of #{session.title || session.id}",
      config: session.config || %{},
      status: "idle",
      inserted_at: now,
      updated_at: now
    }

    copied =
      Enum.map(messages, fn msg ->
        %Message{
          id: Ecto.UUID.generate(),
          session_id: new_session.id,
          role: msg.role,
          parts: msg.parts,
          token_count: msg.token_count,
          internal_turn_source: msg.internal_turn_source
        }
      end)

    with :ok <- persist_fork(session, new_session, copied) do
      {:ok, new_session}
    end
  end

  defp persist_fork(source, destination, messages) do
    meta = Session.to_meta(destination)

    if Sessions.voice?(source) do
      identities =
        messages
        |> Enum.flat_map(&(&1.parts || []))
        |> Enum.flat_map(&voice_fact_identity/1)
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

      Store.publish_voice_fork(
        source.id,
        destination.id,
        Enum.map(messages, &Message.encode/1),
        meta,
        identities
      )
    else
      Message.persist_list(destination.id, messages, meta)
    end
  end

  defp voice_fact_identity(%Part.CommittedAudio{connection_generation: generation, item_id: id})
       when is_binary(generation) and is_binary(id),
       do: [{:voice_transcript, generation <> ":" <> id}]

  defp voice_fact_identity(%Part.SpokenAudio{
         connection_generation: generation,
         item_id: id,
         content_index: index
       })
       when is_binary(generation) and is_binary(id) and is_integer(index),
       do: [{:voice_playback, generation <> ":" <> id <> ":" <> Integer.to_string(index)}]

  defp voice_fact_identity(_), do: []
end
