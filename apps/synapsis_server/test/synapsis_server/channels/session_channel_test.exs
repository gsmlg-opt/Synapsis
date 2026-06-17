defmodule SynapsisServer.SessionChannelTest do
  use SynapsisServer.ChannelCase

  alias SynapsisServer.SessionChannel

  describe "session:steer" do
    setup do
      {:ok, session} =
        Synapsis.Sessions.create("main", %{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })

      socket = %Phoenix.Socket{assigns: %{session_id: session.id}}
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

    test "returns ok for a valid session", %{socket: socket} do
      assert {:reply, :ok, ^socket} =
               SessionChannel.handle_in(
                 "session:steer",
                 %{"content" => "prefer a small patch"},
                 socket
               )
    end
  end
end
