defmodule SynapsisServer.SessionChannelTest do
  use SynapsisServer.ChannelCase

  alias SynapsisServer.SessionChannel

  test "channel join preserves rich tool-result projection history" do
    projection = rich_projection()

    part = %Synapsis.Part.ToolResult{
      tool_use_id: "rich-call",
      content: "before\nafter",
      is_error: false,
      projection: projection
    }

    {session_id, message} = append_history(part)
    assert {:ok, socket} = connect(SynapsisServer.UserSocket, %{})
    assert {:ok, %{messages: [serialized]}, _socket} = join(socket, "session:#{session_id}", %{})

    assert serialized.id == message.id

    assert serialized.parts == [
             %{
               type: "tool_result",
               tool_use_id: "rich-call",
               content: "before\nafter",
               is_error: false,
               projection: projection
             }
           ]
  end

  test "channel join preserves projected errors and their legacy identity" do
    projection = %{
      "version" => 1,
      "result" => %{
        "is_error" => true,
        "error" => %{
          "class" => "execution_failure",
          "message" => "Public failure",
          "details" => %{"retryable" => false, "completed" => 2}
        }
      }
    }

    part = %Synapsis.Part.ToolResult{
      tool_use_id: "error-call",
      content: "Public failure",
      is_error: true,
      projection: projection
    }

    {session_id, _message} = append_history(part)
    assert {:ok, socket} = connect(SynapsisServer.UserSocket, %{})
    assert {:ok, %{messages: [serialized]}, _socket} = join(socket, "session:#{session_id}", %{})

    assert serialized.parts == [
             %{
               type: "tool_result",
               tool_use_id: "error-call",
               content: "Public failure",
               is_error: true,
               projection: projection
             }
           ]
  end

  test "channel join omits nil projections from legacy history" do
    part = %Synapsis.Part.ToolResult{
      tool_use_id: "legacy-call",
      content: "legacy output",
      is_error: false,
      projection: nil
    }

    {session_id, _message} = append_history(part)
    assert {:ok, socket} = connect(SynapsisServer.UserSocket, %{})
    assert {:ok, %{messages: [serialized]}, _socket} = join(socket, "session:#{session_id}", %{})

    assert [legacy] = serialized.parts
    refute Map.has_key?(legacy, :projection)

    assert legacy == %{
             type: "tool_result",
             tool_use_id: "legacy-call",
             content: "legacy output",
             is_error: false
           }
  end

  test "live tool results push the complete public payload unchanged" do
    socket = %Phoenix.Socket{
      joined: true,
      transport_pid: self(),
      topic: "session:tool-result-test",
      serializer: Phoenix.ChannelTest.NoopSerializer
    }

    payload = %{
      tool: "display_fixture",
      tool_use_id: "rich-call",
      content: "before\nafter",
      is_error: false,
      projection: rich_projection()
    }

    assert {:noreply, ^socket} = SessionChannel.handle_info({"tool_result", payload}, socket)
    assert_receive %Phoenix.Socket.Message{event: "tool_result", payload: public}
    assert public == payload
  end

  test "ask_user pushes only public question fields" do
    socket = %Phoenix.Socket{
      joined: true,
      transport_pid: self(),
      topic: "session:question-test",
      serializer: Phoenix.ChannelTest.NoopSerializer
    }

    payload = %{
      ref: "question-ref",
      question: "Which city?",
      options: nil,
      owner: self(),
      deadline_ms: System.monotonic_time(:millisecond) + 10_000
    }

    assert {:noreply, ^socket} =
             SessionChannel.handle_info({:ask_user, "question-ref", payload}, socket)

    assert_receive %Phoenix.Socket.Message{event: "ask_user", payload: public}
    assert public == %{ref: "question-ref", question: "Which city?", options: nil}
  end

  test "legacy channel answers retain the original PubSub reply protocol" do
    session_id = Ecto.UUID.generate()
    Phoenix.PubSub.subscribe(Synapsis.PubSub, "ask_user_response:#{session_id}")
    socket = %Phoenix.Socket{assigns: %{session_id: session_id}}

    assert {:reply, :ok, ^socket} =
             SessionChannel.handle_in(
               "session:ask_user_response",
               %{"ref" => "question-ref", "response" => "Beijing"},
               socket
             )

    assert_receive {:user_response, "question-ref", "Beijing"}
  end

  describe "session:steer" do
    setup do
      socket = %Phoenix.Socket{assigns: %{session_id: Ecto.UUID.generate()}}
      %{socket: socket}
    end

    test "returns an error when content is missing", %{socket: socket} do
      assert {:reply, {:error, %{reason: "content is required"}}, ^socket} =
               SessionChannel.handle_in("session:steer", %{}, socket)
    end

    test "returns an error when content is not a string", %{socket: socket} do
      assert {:reply, {:error, %{reason: "content must be a string"}}, ^socket} =
               SessionChannel.handle_in("session:steer", %{"content" => 123}, socket)
    end

    test "returns an error when content is too large", %{socket: socket} do
      content = String.duplicate("x", 256_001)

      assert {:reply, {:error, %{reason: "content too large"}}, ^socket} =
               SessionChannel.handle_in("session:steer", %{"content" => content}, socket)
    end
  end

  defp append_history(part) do
    session = %Synapsis.Session{
      id: Ecto.UUID.generate(),
      provider: "transport-test",
      model: "test"
    }

    :ok = Synapsis.Session.Store.put_meta(session.id, Synapsis.Session.to_meta(session))
    on_exit(fn -> Synapsis.Sessions.delete(session.id) end)
    {:ok, message} = Synapsis.Message.append(session.id, %{role: "assistant", parts: [part]})
    {session.id, message}
  end

  defp rich_projection do
    %{
      "version" => 1,
      "result" => %{
        "content" => [
          %{"type" => "text", "text" => "before"},
          %{
            "type" => "image",
            "data" => %{
              "source" => "base64",
              "media_type" => "image/png",
              "data" => "aW1hZ2U="
            }
          },
          %{"type" => "text", "text" => "after"}
        ],
        "is_error" => false,
        "structured" => %{"rows" => [%{"value" => 3}]},
        "artifacts" => [%{"uri" => "workspace://report", "name" => "report"}],
        "details" => %{"count" => 1},
        "progress" => %{"status" => "completed", "completed" => 1},
        "pagination" => %{"cursor" => "page-2", "truncated" => true},
        "metadata" => %{"opaque" => [nil, false, 4]}
      }
    }
  end
end
