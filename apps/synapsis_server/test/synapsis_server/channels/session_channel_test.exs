defmodule SynapsisServer.SessionChannelTest do
  use SynapsisServer.ChannelCase

  alias SynapsisServer.SessionChannel

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
end
