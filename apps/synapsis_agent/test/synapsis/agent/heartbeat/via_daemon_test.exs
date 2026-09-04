defmodule Synapsis.Agent.Heartbeat.ViaDaemonTest do
  use Synapsis.Agent.DataCase, async: false

  alias Synapsis.Agent.Daemon
  alias Synapsis.Agent.Heartbeat.{Delivery, Worker}
  alias Synapsis.Agent.Runs
  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.AgentRun

  @moduletag :tmp_dir

  setup do
    Synapsis.DataCase.clear_coord("coord/agent_runs/")
    Synapsis.DataCase.clear_coord("coord/agent_run_events/")
    Synapsis.DataCase.clear_coord("coord/agent_run_event_ids/")
    Synapsis.DataCase.clear_coord("coord/agent_run_idempotency/")
    :ok
  end

  test "trigger creates heartbeat AgentRun and completes", %{tmp_dir: tmp_dir} do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: tmp_dir,
        scenario: :success,
        text: "heartbeat pulse ok"
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)

    assert {:ok, run} =
             Daemon.trigger(:heartbeat, "hb-success-1",
               prompt: "status check",
               agent: harness.agent_name,
               provider: harness.provider.name,
               model: "characterization-model",
               idempotency_key: "hb-success-key-1",
               name: "pulse"
             )

    assert run.kind == "heartbeat"
    assert run.tool_profile == "heartbeat"
    assert run.source == "scheduler"
    assert is_binary(run.id)

    assert_run_terminal(run.id, "completed", 20_000)

    Daemon.record_heartbeat_outcome("hb-success-1", :completed)
    Process.sleep(20)
    status = Daemon.status()
    assert %DateTime{} = status.last_heartbeat_success_at
    assert status.heartbeat_failure_streak == 0
  end

  test "provider failure yields failed run not completed", %{tmp_dir: tmp_dir} do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: tmp_dir,
        scenario: :provider_failure,
        text: "nope"
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)

    assert {:ok, run} =
             Daemon.trigger(:heartbeat, "hb-fail-1",
               prompt: "fail please",
               agent: harness.agent_name,
               provider: harness.provider.name,
               model: "characterization-model",
               idempotency_key: "hb-fail-key-1"
             )

    assert_run_terminal(run.id, "failed", 20_000)
    Daemon.record_heartbeat_outcome("hb-fail-1", :failed)
    Process.sleep(20)
    assert Daemon.status().heartbeat_failure_streak >= 1
  end

  test "deadline yields timed_out", %{tmp_dir: tmp_dir} do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: tmp_dir,
        scenario: :hang,
        hang_ms: 5_000,
        text: "slow"
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)

    deadline = DateTime.add(DateTime.utc_now(), 400, :millisecond)

    assert {:ok, run} =
             Daemon.trigger(:heartbeat, "hb-deadline-1",
               prompt: "deadline",
               agent: harness.agent_name,
               provider: harness.provider.name,
               model: "characterization-model",
               idempotency_key: "hb-deadline-key-1",
               deadline_at: deadline
             )

    assert_run_terminal(run.id, "timed_out", 10_000)
  end

  test "Worker.execute disabled is ok without run" do
    assert :ok =
             Worker.execute(%{
               id: "disabled",
               name: "disabled",
               enabled: false,
               prompt: "x",
               agent_name: "main"
             })
  end

  test "delivery failure does not rewrite completed execution", %{tmp_dir: tmp_dir} do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: tmp_dir,
        scenario: :success,
        text: "deliver me"
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)

    assert {:ok, run} =
             Daemon.trigger(:heartbeat, "hb-deliver-1",
               prompt: "deliver",
               agent: harness.agent_name,
               provider: harness.provider.name,
               model: "characterization-model",
               idempotency_key: "hb-deliver-key-1"
             )

    assert_run_terminal(run.id, "completed", 20_000)
    completed = Runs.get(run.id)
    assert completed.status == "completed"

    # Delivery with notify; even if workspace write is best-effort, status stays completed.
    assert :ok =
             Delivery.deliver(completed, %{
               id: "hb-deliver-1",
               name: "deliver_test",
               notify_user: true,
               keep_history: false
             })

    assert %{status: "completed"} = Runs.get(run.id)
  end

  test "idempotent heartbeat trigger returns same run" do
    key = "hb-idem-#{System.unique_integer([:positive])}"

    assert {:ok, first} =
             Daemon.trigger(:heartbeat, "hb-idem",
               prompt: "idem",
               agent: "main",
               idempotency_key: key
             )

    # Mark terminal so coordinator exit does not race second create path
    if not AgentRun.terminal?(first) do
      _ = Runs.mark_failed(Runs.get(first.id), "stop for idempotency test")
    end

    assert {:ok, second} =
             Daemon.trigger(:heartbeat, "hb-idem",
               prompt: "idem",
               agent: "main",
               idempotency_key: key
             )

    assert first.id == second.id
  end

  test "failure streak resets after success" do
    Daemon.record_heartbeat_outcome("streak-r", :failed)
    Daemon.record_heartbeat_outcome("streak-r", :failed)
    Process.sleep(20)
    assert Daemon.status().heartbeat_failure_streak >= 1

    Daemon.record_heartbeat_outcome("streak-r", :completed)
    Process.sleep(20)
    assert Daemon.status().heartbeat_failure_streak == 0
  end

  defp assert_run_terminal(run_id, status, timeout_ms) do
    wait_until(fn -> match?(%{status: ^status}, Runs.get(run_id)) end, timeout_ms)
    assert %{status: ^status} = Runs.get(run_id)
  end

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      if fun.() do
        :ok
      else
        if System.monotonic_time(:millisecond) > deadline do
          flunk("condition not met within #{timeout_ms}ms")
        end

        Process.sleep(50)
        :retry
      end
    end)
    |> Enum.find(&(&1 == :ok))
  end
end
