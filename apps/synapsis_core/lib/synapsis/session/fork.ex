defmodule Synapsis.Session.Fork do
  @moduledoc "Fork a session at a given message, creating a new branch."

  alias Synapsis.{Message, Session, Sessions}
  alias Synapsis.Session.Store

  def fork(session_id, opts \\ []) do
    message_id = Keyword.get(opts, :at_message)

    case Sessions.get(session_id) do
      {:error, :not_found} -> {:error, :not_found}
      {:ok, session} -> do_fork(session, message_id)
    end
  end

  defp do_fork(session, message_id) do
    messages = load_messages(session.id)

    messages_to_copy =
      if message_id do
        target = Enum.find(messages, fn m -> m.id == message_id end)

        if is_nil(target) do
          :message_not_found
        else
          Enum.take_while(messages, fn m -> m.id != message_id end) ++ [target]
        end
      else
        messages
      end

    if messages_to_copy == :message_not_found do
      {:error, :message_not_found}
    else
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
        Enum.map(messages_to_copy, fn msg ->
          %Message{
            session_id: new_session.id,
            role: msg.role,
            parts: msg.parts,
            token_count: msg.token_count
          }
        end)

      Store.put_meta(new_session.id, Session.to_meta(new_session))
      :ok = Message.persist_list(new_session.id, copied)
      {:ok, new_session}
    end
  end

  defp load_messages(session_id), do: Message.list_by_session(session_id)
end
