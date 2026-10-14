defmodule SynapsisWeb.ChatBridgeTest do
  use ExUnit.Case, async: true

  alias SynapsisWeb.ChatBridge

  setup do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

    snapshot = %{
      messages: [%{id: "reply", role: "assistant", content: "", status: "streaming"}],
      metadata: %{},
      runtime: %{active: true},
      admission: %{allowWhileStreaming: true}
    }

    %{socket: ChatBridge.start(socket, "chat", "session", snapshot), snapshot: snapshot}
  end

  test "deltas and replacements share monotonic sequences and canonical text", %{
    socket: socket,
    snapshot: initial
  } do
    socket = ChatBridge.delta(socket, "reply", "Hello")
    socket = ChatBridge.delta(socket, "reply", " world")
    assert [%{content: "Hello world"}] = socket.assigns.react_chat.messages
    assert socket.assigns.react_chat.sequences == %{"reply" => 2}

    final = %{
      initial
      | messages: [%{id: "reply", role: "assistant", content: "Hello world", status: "complete"}],
        runtime: %{active: false}
    }

    socket = ChatBridge.sync(socket, final)
    assert socket.assigns.react_chat.sequences == %{"reply" => 3}
    events = Enum.reverse(socket.private.live_temp[:push_events])

    assert Enum.map(events, fn [_, payload] -> payload.type end) == [
             "chat.delta",
             "chat.delta",
             "chat.message"
           ]

    assert Enum.map(events, fn [_, payload] -> payload.sequence end) == [1, 2, 3]
  end

  test "removing an in-flight row publishes a recoverable snapshot", %{
    socket: socket,
    snapshot: initial
  } do
    socket = ChatBridge.delta(socket, "reply", "Partial")

    final = %{
      initial
      | messages: [%{id: "persisted", role: "assistant", content: "Partial", status: "complete"}]
    }

    socket = socket |> ChatBridge.sync(final) |> ChatBridge.snapshot()
    [_, payload] = List.first(socket.private.live_temp[:push_events])
    assert payload.type == "chat.snapshot"
    assert payload.messages == final.messages
    assert payload.sequences == %{"reply" => 1}
    refute Map.has_key?(payload, :requests)
  end

  test "runtime updates publish even without messages and unchanged state stays silent", %{
    socket: socket,
    snapshot: initial
  } do
    socket = ChatBridge.sync(socket, initial)
    assert socket.private.live_temp[:push_events] in [nil, []]
    final = %{initial | messages: [], runtime: %{active: false}}
    socket = ChatBridge.sync(socket, final)

    assert [["chat:event", %{type: "chat.snapshot", runtime: %{active: false}}]] =
             socket.private.live_temp[:push_events]
  end

  test "conversation scope and admitted request cache do not cross mounts", %{
    socket: socket,
    snapshot: initial
  } do
    assert ChatBridge.valid_scope?(socket, %{"id" => "chat", "conversation_id" => "session"})
    refute ChatBridge.valid_scope?(socket, %{"id" => "chat", "conversation_id" => "old"})
    refute ChatBridge.valid_scope?(socket, %{"id" => "other", "conversation_id" => "session"})
    socket = ChatBridge.remember_request(socket, "request", %{status: "ok"})
    assert ChatBridge.request_reply(socket, "request") == %{status: "ok"}
    socket = ChatBridge.start(socket, "new-chat", "new-session", initial)
    assert ChatBridge.request_reply(socket, "request") == nil
    assert socket.assigns.react_chat.sequences == %{}
  end

  test "reselecting the same conversation preserves counters, requests and initial mount", %{
    socket: socket,
    snapshot: initial
  } do
    socket =
      socket
      |> ChatBridge.delta("reply", "Hello")
      |> ChatBridge.remember_request("request", %{status: "ok"})

    current = %{initial | messages: socket.assigns.react_chat.messages}
    socket = ChatBridge.start(socket, "chat", "session", current)
    assert socket.assigns.react_chat.sequences == %{"reply" => 1}
    assert ChatBridge.request_reply(socket, "request") == %{status: "ok"}
    assert socket.assigns.react_chat_initial.messages == initial.messages
    [_, payload] = List.first(socket.private.live_temp.push_events)
    assert payload.type == "chat.snapshot"
    assert payload.sequences == %{"reply" => 1}
    socket = ChatBridge.delta(socket, "reply", " again")
    assert socket.assigns.react_chat.sequences == %{"reply" => 2}
  end
end
