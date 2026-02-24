defmodule SynapsisServer.UserSocketTest do
  use SynapsisServer.ChannelCase

  alias SynapsisServer.UserSocket

  describe "connect/3" do
    test "accepts connections with no params" do
      assert {:ok, _socket} = connect(UserSocket, %{})
    end

    test "accepts connections with arbitrary params" do
      assert {:ok, _socket} = connect(UserSocket, %{"token" => "some_value"})
    end

    test "returns a usable socket struct" do
      {:ok, socket} = connect(UserSocket, %{})
      assert %Phoenix.Socket{} = socket
    end
  end

  describe "id/1" do
    test "returns nil (no user-specific socket identification)" do
      {:ok, socket} = connect(UserSocket, %{})
      assert UserSocket.id(socket) == nil
    end
  end

  describe "channel routing" do
    setup do
      {:ok, project} =
        %Synapsis.Project{}
        |> Synapsis.Project.changeset(%{
          path: "/tmp/user_socket_test_#{:rand.uniform(100_000)}",
          slug: "user-socket-test-#{:rand.uniform(100_000)}"
        })
        |> Synapsis.Repo.insert()

      {:ok, session} =
        %Synapsis.Session{}
        |> Synapsis.Session.changeset(%{
          project_id: project.id,
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })
        |> Synapsis.Repo.insert()

      %{session: session}
    end

    test "routes session:* topic to SessionChannel", %{session: session} do
      {:ok, socket} = connect(UserSocket, %{})

      {:ok, _reply, socket} =
        subscribe_and_join(socket, "session:#{session.id}")

      assert socket.assigns.session_id == session.id
    end

    test "can join session channel with valid session id", %{session: session} do
      {:ok, reply, _socket} =
        UserSocket
        |> socket("test_user", %{})
        |> subscribe_and_join(SynapsisServer.SessionChannel, "session:#{session.id}")

      assert is_map(reply)
      assert Map.has_key?(reply, :messages)
    end

    test "join reply contains messages list", %{session: session} do
      {:ok, reply, _socket} =
        UserSocket
        |> socket("test_user", %{})
        |> subscribe_and_join(SynapsisServer.SessionChannel, "session:#{session.id}")

      assert is_list(reply.messages)
    end

    test "multiple clients can join the same session channel", %{session: session} do
      {:ok, _reply1, _socket1} =
        UserSocket
        |> socket("user_1", %{})
        |> subscribe_and_join(SynapsisServer.SessionChannel, "session:#{session.id}")

      {:ok, _reply2, _socket2} =
        UserSocket
        |> socket("user_2", %{})
        |> subscribe_and_join(SynapsisServer.SessionChannel, "session:#{session.id}")
    end

    test "session_id is assigned in socket after join", %{session: session} do
      {:ok, _reply, socket} =
        UserSocket
        |> socket("test_user", %{})
        |> subscribe_and_join(SynapsisServer.SessionChannel, "session:#{session.id}")

      assert socket.assigns[:session_id] == session.id
    end
  end
end
