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
        # Copy up to and including the specified message
        (Enum.take_while(messages, fn m -> m.id != message_id end) ++
           [Enum.find(messages, fn m -> m.id == message_id end)])
        |> Enum.reject(&is_nil/1)
      else
        messages
      end

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
      {:ok, new_session} =
        %Session{}
        |> Session.changeset(attrs)
        |> Repo.insert()

      for msg <- messages_to_copy do
        %Message{}
        |> Message.changeset(%{
          session_id: new_session.id,
          role: msg.role,
          parts: msg.parts,
          token_count: msg.token_count
        })
        |> Repo.insert!()
      end

      Repo.preload(new_session, :project)
    end)
  end

  defp load_messages(session_id) do
    Message
    |> where([m], m.session_id == ^session_id)
    |> order_by([m], asc: m.inserted_at)
    |> Repo.all()
  end
end
