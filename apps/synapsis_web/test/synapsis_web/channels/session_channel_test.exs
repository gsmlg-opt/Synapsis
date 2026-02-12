defmodule SynapsisWeb.SessionChannelTest do
  use SynapsisWeb.ChannelCase

  alias SynapsisWeb.UserSocket

  setup do
    # Create a session for testing
    {:ok, project} =
      %Synapsis.Project{}
      |> Synapsis.Project.changeset(%{
        path: "/tmp/channel_test_#{:rand.uniform(100_000)}",
        slug: "channel-test-#{:rand.uniform(100_000)}"
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

    {:ok, _, socket} =
      UserSocket
      |> socket("user_id", %{})
      |> subscribe_and_join(SynapsisWeb.SessionChannel, "session:#{session.id}")

    %{socket: socket, session: session}
  end

  test "joins session channel", %{socket: socket} do
    assert socket.assigns.session_id
  end

  test "handles cancel event", %{socket: socket} do
    ref = push(socket, "session:cancel", %{})
    assert_reply ref, :ok
  end
end
