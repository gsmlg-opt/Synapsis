defmodule Synapsis.Session.Worker.Persistence do
  @moduledoc "Message persistence and session status updates for Worker."

  require Logger

  alias Synapsis.{Session, Message, ContextWindow}
  alias Synapsis.Session.Store

  @image_token_estimate 1_000

  def persist_user_message(session_id, content, image_parts) do
    parts = [%Synapsis.Part.Text{content: content} | image_parts]

    token_count =
      ContextWindow.estimate_tokens(content) + length(image_parts) * @image_token_estimate

    # ADR-006 C4: a message is a durable Concord turn.
    case Message.append(session_id, %Message{role: "user", parts: parts, token_count: token_count}) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  def update_session_status(session_id, status) do
    case Store.get_meta(session_id) do
      {:error, :not_found} ->
        :ok

      {:ok, meta} ->
        session = Session.from_meta(meta)
        updated = %{session | status: status, updated_at: DateTime.utc_now()}
        Store.put_meta(session_id, Session.to_meta(updated))
        {:ok, updated}
    end
  rescue
    e ->
      Logger.warning("update_session_status_failed",
        session_id: session_id,
        error: Exception.message(e)
      )

      :ok
  end

  def has_messages?(session_id) do
    Message.list_by_session(session_id) != []
  end

  def set_status(session_id, status) do
    _ = update_session_status(session_id, status)
    broadcast(session_id, "session_status", %{status: status})
  end

  def broadcast(session_id, event, payload),
    do: Phoenix.PubSub.broadcast(Synapsis.PubSub, "session:#{session_id}", {event, payload})
end
