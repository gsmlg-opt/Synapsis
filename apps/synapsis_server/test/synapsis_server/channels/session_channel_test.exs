defmodule SynapsisServer.SessionChannelTest do
  use SynapsisServer.ChannelCase

  alias SynapsisServer.UserSocket

  setup do
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
      |> subscribe_and_join(SynapsisServer.SessionChannel, "session:#{session.id}")

    %{socket: socket, session: session}
  end

  test "joins session channel", %{socket: socket} do
    assert socket.assigns.session_id
  end

  test "handles cancel event", %{socket: socket} do
    ref = push(socket, "session:cancel", %{})
    assert_reply ref, :ok
  end

  test "handles tool approve event", %{socket: socket} do
    ref = push(socket, "session:tool_approve", %{"tool_use_id" => "tu_123"})
    assert_reply ref, :ok
  end

  test "handles tool deny event", %{socket: socket} do
    ref = push(socket, "session:tool_deny", %{"tool_use_id" => "tu_456"})
    assert_reply ref, :ok
  end

  test "handles switch agent event", %{socket: socket} do
    ref = push(socket, "session:switch_agent", %{"agent" => "plan"})
    # May succeed or fail depending on session state, but should not crash
    assert_reply ref, _status
  end

  test "forwards orchestrator_pause event from PubSub", %{socket: _socket, session: session} do
    Phoenix.PubSub.broadcast(
      Synapsis.PubSub,
      "session:#{session.id}",
      {"orchestrator_pause", %{reason: "Stagnation detected"}}
    )

    assert_push "orchestrator_pause", %{reason: "Stagnation detected"}
  end

  test "forwards orchestrator_escalate event from PubSub", %{socket: _socket, session: session} do
    Phoenix.PubSub.broadcast(
      Synapsis.PubSub,
      "session:#{session.id}",
      {"orchestrator_escalate", %{reason: "Duplicate tool calls"}}
    )

    assert_push "orchestrator_escalate", %{reason: "Duplicate tool calls"}
  end

  test "forwards orchestrator_terminate event from PubSub", %{socket: _socket, session: session} do
    Phoenix.PubSub.broadcast(
      Synapsis.PubSub,
      "session:#{session.id}",
      {"orchestrator_terminate", %{reason: "Max iterations reached"}}
    )

    assert_push "orchestrator_terminate", %{reason: "Max iterations reached"}
  end

  test "forwards auditing event from PubSub", %{socket: _socket, session: session} do
    Phoenix.PubSub.broadcast(
      Synapsis.PubSub,
      "session:#{session.id}",
      {"auditing", %{reason: "Duplicate tool calls"}}
    )

    assert_push "auditing", %{reason: "Duplicate tool calls"}
  end

  test "forwards constraint_added event from PubSub", %{socket: _socket, session: session} do
    Phoenix.PubSub.broadcast(
      Synapsis.PubSub,
      "session:#{session.id}",
      {"constraint_added",
       %{attempt_number: 1, error_message: "Repeated same edit", lesson: "Try a different file"}}
    )

    assert_push "constraint_added", %{
      attempt_number: 1,
      error_message: "Repeated same edit",
      lesson: "Try a different file"
    }
  end

  test "forwards text_delta event from PubSub", %{socket: _socket, session: session} do
    Phoenix.PubSub.broadcast(
      Synapsis.PubSub,
      "session:#{session.id}",
      {"text_delta", %{text: "Hello"}}
    )

    assert_push "text_delta", %{text: "Hello"}
  end

  test "forwards permission_request event from PubSub", %{socket: _socket, session: session} do
    Phoenix.PubSub.broadcast(
      Synapsis.PubSub,
      "session:#{session.id}",
      {"permission_request", %{tool: "bash", tool_use_id: "tu_789", input: %{"command" => "ls"}}}
    )

    assert_push "permission_request", %{tool: "bash", tool_use_id: "tu_789"}
  end

  test "ignores unknown handle_in events", %{socket: socket} do
    ref = push(socket, "unknown:event", %{})
    refute_reply ref, _
  end
end
