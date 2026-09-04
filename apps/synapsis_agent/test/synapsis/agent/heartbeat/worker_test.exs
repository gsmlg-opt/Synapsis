defmodule Synapsis.Agent.Heartbeat.WorkerTest do
  use Synapsis.Agent.DaemonCase, async: false

  alias Synapsis.Agent.Heartbeat.Worker

  test "execute/1 returns :ok for a disabled config" do
    config = %{
      id: "test-id",
      name: "disabled",
      schedule: "0 9 * * *",
      enabled: false,
      prompt: "hello"
    }

    assert :ok = Worker.execute(config)
  end

  test "execute/2 adapts an enabled legacy config to the daemon trigger" do
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :waiting)
    {daemon, _task_supervisor} = start_test_daemon(sessions: FakeSessions)
    heartbeat_id = Ecto.UUID.generate()

    config = %{
      id: heartbeat_id,
      name: "legacy-adapter",
      schedule: "0 9 * * *",
      enabled: true,
      prompt: "route through daemon",
      agent_name: "main",
      no_overlap: true,
      max_runtime_ms: 1_000
    }

    assert {:ok, run} = Worker.execute(config, daemon)
    assert run.kind == "heartbeat"
    assert run.heartbeat_id == heartbeat_id
    assert_receive {:waiting_session, _session_id}, 1_000
    assert {:ok, _cancelled} = Daemon.cancel(daemon, run.id)
  end
end
