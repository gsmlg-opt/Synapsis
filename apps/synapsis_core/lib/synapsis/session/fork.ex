defmodule Synapsis.Session.Fork do
  @moduledoc "Fork a session at a given message, creating a new branch."

  alias Synapsis.{Repo, Session, Message}
  import Ecto.Query

  def fork(session_id, opts \\ []) do
    message_id = Keyword.get(opts, :at_message)

    case Repo.get(Session, session_id) do
      nil -> {:error, :not_found}
      session -> do_fork(session, message_id)
    end
  end

  defp do_fork(session, message_id) do
    session = Repo.preload(session, :project)
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
      title = "Fork of #{session.title || session.id}"

      attrs = %{
        project_id: session.project_id,
        provider: session.provider,
        model: session.model,
        agent: session.agent,
        title: title,
        config: session.config
      }

      Repo.transaction(fn ->
        new_session =
          case %Session{}
               |> Session.changeset(attrs)
               |> Repo.insert() do
            {:ok, s} -> s
            {:error, changeset} -> Repo.rollback(changeset)
          end

        for msg <- messages_to_copy do
          case %Message{}
               |> Message.changeset(%{
                 session_id: new_session.id,
                 role: msg.role,
                 parts: msg.parts,
                 token_count: msg.token_count
               })
               |> Repo.insert() do
            {:ok, _} -> :ok
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end

        Repo.preload(new_session, :project)
      end)
    end
  end

  defp load_messages(session_id) do
    Message
    |> where([m], m.session_id == ^session_id)
    |> order_by([m], asc: m.inserted_at)
    |> Repo.all()
  end
end
