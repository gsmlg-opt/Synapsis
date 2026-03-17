defmodule Synapsis.Session.Worker.Persistence do
  @moduledoc "Message persistence and session status updates for Worker."

  require Logger

  alias Synapsis.{Repo, Session, Message, ContextWindow}

  def persist_user_message(session_id, content, image_parts) do
    parts = [%Synapsis.Part.Text{content: content} | image_parts]
    token_count = ContextWindow.estimate_tokens(content) + length(image_parts) * 1000

    case %Message{}
         |> Message.changeset(%{
           session_id: session_id,
           role: "user",
           parts: parts,
           token_count: token_count
         })
         |> Repo.insert() do
      {:ok, _} ->
        :ok

      {:error, cs} ->
        Logger.warning("message_insert_failed",
          session_id: session_id,
          errors: inspect(cs.errors)
        )
    end
  end

  def update_session_status(session_id, status) do
    case Repo.get(Session, session_id) do
      nil -> :ok
      session -> session |> Session.status_changeset(status) |> Repo.update()
    end
  rescue
    error ->
      Logger.warning("update_session_status_failed",
        session_id: session_id,
        error: inspect(error)
      )

      :ok
  end

  def has_messages?(session_id) do
    import Ecto.Query, only: [from: 2]
    Repo.exists?(from(m in Message, where: m.session_id == ^session_id))
  end

  def set_status(session_id, status) do
    update_session_status(session_id, status)
    broadcast(session_id, "session_status", %{status: status})
  end

  def broadcast(session_id, event, payload),
    do: Phoenix.PubSub.broadcast(Synapsis.PubSub, "session:#{session_id}", {event, payload})
end
