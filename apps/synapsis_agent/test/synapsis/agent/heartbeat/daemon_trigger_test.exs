defmodule Synapsis.Agent.Heartbeat.DaemonTriggerTest do
  use Synapsis.Agent.DaemonCase, async: false

  setup do
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :waiting)
    :ok
  end

  test "manual heartbeat trigger creates a normal heartbeat AgentRun" do
    {daemon, _task_supervisor} = start_test_daemon(sessions: FakeSessions)
    heartbeat_id = Ecto.UUID.generate()

    assert {:ok, run} =
             Daemon.trigger(daemon, :heartbeat, %{
               heartbeat_id: heartbeat_id,
               prompt: "check recent work"
             })

    assert run.kind == "heartbeat"
    assert run.heartbeat_id == heartbeat_id
    assert run.routine_id == heartbeat_id
    assert run.source == "system"
    assert run.tool_profile == "assistant_basic"
    assert run.metadata["no_overlap"] == true
    assert_receive {:waiting_session, _session_id}, 1_000
    assert {:ok, _cancelled} = Daemon.cancel(daemon, run.id)
  end

  test "no-overlap rejects a second heartbeat for the same routine" do
    {daemon, _task_supervisor} = start_test_daemon(sessions: FakeSessions)
    heartbeat_id = Ecto.UUID.generate()
    opts = %{heartbeat_id: heartbeat_id, prompt: "do not overlap"}

    assert {:ok, first} = Daemon.trigger(daemon, :heartbeat, opts)
    assert_receive {:waiting_session, _session_id}, 1_000
    assert {:error, :overlap} = Daemon.trigger(daemon, :heartbeat, opts)

    assert [persisted] =
             Enum.filter(Runs.list_recent(limit: 10), &(&1.heartbeat_id == heartbeat_id))

    assert persisted.id == first.id
    assert {:ok, _cancelled} = Daemon.cancel(daemon, first.id)
  end

  test "heartbeat max runtime overrides the daemon default" do
    {daemon, _task_supervisor} =
      start_test_daemon(sessions: FakeSessions, run_timeout: 2_000, cleanup_timeout: 50)

    started_at = System.monotonic_time(:millisecond)

    assert {:ok, run} =
             Daemon.trigger(daemon, :heartbeat, %{
               heartbeat_id: Ecto.UUID.generate(),
               prompt: "bounded heartbeat",
               max_runtime_ms: 50
             })

    assert_receive {:waiting_session, _session_id}, 1_000
    assert {:ok, failed} = wait_for_run(run.id, "failed")
    assert failed.error =~ "session_timeout"
    assert System.monotonic_time(:millisecond) - started_at < 1_000
  end
end
