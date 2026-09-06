defmodule SynapsisServer.AgentDaemonEventTest do
  use ExUnit.Case, async: true

  alias SynapsisServer.AgentDaemonEvent

  test "maps the complete daemon event vocabulary to external names" do
    mappings = [
      {"agent.daemon.status", "daemon_status"},
      {"agent.run.queued", "run_queued"},
      {"agent.run.started", "run_started"},
      {"agent.run.completed", "run_completed"},
      {"agent.run.failed", "run_failed"},
      {"agent.run.cancelled", "run_cancelled"},
      {"agent.run.interrupted", "run_interrupted"},
      {"agent.routine.triggered", "routine_triggered"},
      {"agent.routine.updated", "routine_updated"},
      {"backplane.sync.started", "backplane_sync_started"},
      {"backplane.sync.completed", "backplane_sync_completed"},
      {"backplane.sync.failed", "backplane_sync_failed"},
      {"backplane.capabilities.updated", "capabilities_updated"}
    ]

    for {internal, external} <- mappings do
      message = {:agent_daemon_event, %{event: internal, id: "event-id"}}

      assert {:ok, {^external, %{id: "event-id"}}} = AgentDaemonEvent.map(message)
    end
  end

  test "ignores unknown and malformed messages" do
    assert :ignore =
             AgentDaemonEvent.map({:agent_daemon_event, %{event: "agent.internal.secret"}})

    assert :ignore = AgentDaemonEvent.map({:agent_daemon_event, %{}})
    assert :ignore = AgentDaemonEvent.map({:agent_daemon_event, "invalid"})
    assert :ignore = AgentDaemonEvent.map({:unrelated, %{event: "agent.run.started"}})
  end
end
