defmodule Synapsis.Session.Fork do
  @moduledoc "Fork a session at a given message, creating a new branch."

  alias Synapsis.{Message, Session, Sessions}

  @doc "Copy through `:at_message`, or stop before it with `include_message: false`."
  def fork(session_id, opts \\ []) do
    message_id = Keyword.get(opts, :at_message)
    include_message? = Keyword.get(opts, :include_message, true)

    with {:ok, session} <- Sessions.get(session_id),
         {:ok, messages} <- prefix(session.messages, message_id, include_message?) do
      do_fork(session, messages)
    end
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

    with :ok <- Message.persist_list(new_session.id, copied, Session.to_meta(new_session)) do
      {:ok, new_session}
    end
  end
end
