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

  @doc """
  Truncates the durable transcript so a target assistant message can be
  regenerated: keeps every message *before* the target, drops the target and
  everything after it (later turns were conditioned on the response being
  regenerated and are no longer valid).

  Returns `{:ok, user_text}` where `user_text` is the most recent user
  message in the kept prefix (drives the receive node and memory search; the
  prompt itself is rebuilt from the truncated transcript). Rejects a target
  that is missing, not an assistant message, or has no preceding user message.
  """
  def truncate_to_regenerate(session_id, message_id) do
    messages = Message.list_by_session(session_id)

    case Enum.split_while(messages, &(&1.id != message_id)) do
      {_prefix, []} ->
        {:error, :message_not_found}

      {prefix, [%Message{role: "assistant"} | _]} ->
        case latest_user_text(prefix) do
          nil ->
            {:error, :no_user_context}

          user_text ->
            with :ok <- Message.persist_list(session_id, prefix), do: {:ok, user_text}
        end

      {_prefix, [_other | _]} ->
        {:error, :not_assistant_message}
    end
  end

  defp latest_user_text(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message{role: "user", parts: parts} when is_list(parts) ->
        Enum.find_value(parts, fn
          %Synapsis.Part.Text{content: c} when is_binary(c) -> c
          _ -> nil
        end)

      _ ->
        nil
    end)
  end

  def set_status(session_id, status) do
    _ = update_session_status(session_id, status)
    broadcast(session_id, "session_status", %{status: status})
  end

  def broadcast(session_id, event, payload),
    do: Phoenix.PubSub.broadcast(Synapsis.PubSub, "session:#{session_id}", {event, payload})
end
