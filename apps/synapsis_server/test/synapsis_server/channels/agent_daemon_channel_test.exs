defmodule SynapsisServer.AgentDaemonChannelTest do
  use SynapsisServer.ChannelCase

  alias SynapsisServer.UserSocket

  test "joins the exact daemon topic and pushes each mapped event once" do
    assert {:ok, socket} = connect(UserSocket, %{})
    assert {:ok, %{status: status}, _socket} = join(socket, "agent:daemon", %{})
    assert %{ready: _ready, queued_count: _queued_count} = status

    mappings = [
      {"agent.daemon.status", "daemon_status"},
      {"agent.run.queued", "run_queued"},
      {"agent.run.started", "run_started"},
      {"agent.run.completed", "run_completed"},
      {"agent.run.failed", "run_failed"},
      {"agent.routine.triggered", "routine_triggered"},
      {"backplane.sync.started", "backplane_sync_started"},
      {"backplane.sync.completed", "backplane_sync_completed"},
      {"backplane.sync.failed", "backplane_sync_failed"},
      {"backplane.capabilities.updated", "capabilities_updated"}
    ]

    for {internal, external} <- mappings do
      Phoenix.PubSub.broadcast(
        Synapsis.PubSub,
        "agent:daemon",
        {:agent_daemon_event, %{event: internal, event_id: internal}}
      )

      assert_push ^external, %{event_id: ^internal}
    end

    refute_push "run_queued", _duplicate

    Phoenix.PubSub.broadcast(
      Synapsis.PubSub,
      "agent:daemon",
      {:agent_daemon_event, %{event: "internal.unknown", secret: "ignored"}}
    )

    refute_push "internal.unknown", _unknown
  end

  test "rejects input because the daemon channel is read-only" do
    assert {:ok, socket} = connect(UserSocket, %{})
    assert {:ok, _reply, socket} = join(socket, "agent:daemon", %{})

    ref = push(socket, "agent.run", %{})
    assert_reply ref, :error, %{reason: "read_only"}
  end
end
