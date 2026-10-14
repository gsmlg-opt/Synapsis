defmodule SynapsisWeb.ChatBridge do
  @moduledoc "Canonical presentation snapshots and ordered events for React Chat islands."

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  def start(socket, id, conversation_id, snapshot) do
    case socket.assigns[:react_chat] do
      %{id: ^id, conversation_id: ^conversation_id} ->
        socket |> sync(snapshot) |> snapshot()

      _ ->
        initialize(socket, id, conversation_id, snapshot)
    end
  end

  defp initialize(socket, id, conversation_id, snapshot) do
    chat =
      Map.merge(snapshot, %{
        id: id,
        conversation_id: conversation_id,
        sequences: %{},
        requests: %{}
      })

    socket |> assign(:react_chat, chat) |> assign(:react_chat_initial, chat)
  end

  def valid_scope?(socket, params) do
    case socket.assigns[:react_chat] do
      %{id: id, conversation_id: conversation_id} ->
        params["id"] == id and params["conversation_id"] == conversation_id

      _ ->
        false
    end
  end

  def request_reply(socket, request_id),
    do: Map.get(socket.assigns.react_chat.requests, request_id)

  def remember_request(socket, request_id, reply) when is_binary(request_id) do
    chat = socket.assigns.react_chat
    requests = if map_size(chat.requests) >= 128, do: %{}, else: chat.requests
    assign(socket, :react_chat, %{chat | requests: Map.put(requests, request_id, reply)})
  end

  def remember_request(socket, _request_id, _reply), do: socket

  def sync(socket, snapshot) do
    chat = socket.assigns.react_chat
    previous_ids = Enum.map(chat.messages, & &1.id)
    next_ids = Enum.map(snapshot.messages, & &1.id)
    previous = Map.new(chat.messages, &{&1.id, &1})
    removed_or_reordered? = Enum.filter(next_ids, &Map.has_key?(previous, &1)) != previous_ids
    changed = Enum.filter(snapshot.messages, &(Map.get(previous, &1.id) != &1))

    application_changed? =
      Enum.any?([:metadata, :runtime, :admission], &(chat[&1] != snapshot[&1]))

    socket = assign(socket, :react_chat, Map.merge(chat, snapshot))

    cond do
      removed_or_reordered? ->
        snapshot(socket)

      changed != [] ->
        Enum.reduce(changed, socket, &publish_message(&2, &1))

      application_changed? and snapshot.messages != [] ->
        publish_message(socket, List.last(snapshot.messages))

      application_changed? ->
        snapshot(socket)

      true ->
        socket
    end
  end

  def delta(socket, message_id, text) do
    chat = socket.assigns.react_chat

    messages =
      Enum.map(chat.messages, fn
        %{id: ^message_id, status: "streaming"} = message ->
          Map.update(message, :content, text, &(&1 <> text))

        message ->
          message
      end)

    socket
    |> assign(:react_chat, %{chat | messages: messages})
    |> ordered_event("chat.delta", message_id, %{text: text})
  end

  def snapshot(socket) do
    chat = socket.assigns.react_chat
    payload = chat |> Map.drop([:requests]) |> Map.put(:type, "chat.snapshot")
    push_event(socket, "chat:event", payload)
  end

  defp publish_message(socket, message),
    do: ordered_event(socket, "chat.message", message.id, %{message: message})

  defp ordered_event(socket, type, message_id, payload) do
    chat = socket.assigns.react_chat
    sequence = Map.get(chat.sequences, message_id, 0) + 1

    socket =
      assign(socket, :react_chat, %{
        chat
        | sequences: Map.put(chat.sequences, message_id, sequence)
      })

    payload =
      Map.merge(payload, %{
        id: chat.id,
        conversation_id: chat.conversation_id,
        type: type,
        message_id: message_id,
        sequence: sequence,
        metadata: chat.metadata,
        runtime: chat.runtime,
        admission: chat.admission
      })

    push_event(socket, "chat:event", payload)
  end
end
