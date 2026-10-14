defmodule Synapsis.Agent.Heartbeat.ViaDaemonTest do
  use Synapsis.Agent.DaemonCase, async: false

  alias Synapsis.Agent.Daemon
  alias Synapsis.Agent.Heartbeat.{Delivery, Worker}
  alias Synapsis.Agent.Runs
  alias Synapsis.Agent.TestSupport.SessionHarness

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous_workspace_root = System.get_env("SYNAPSIS_WORKSPACE_ROOT")
    System.put_env("SYNAPSIS_WORKSPACE_ROOT", Path.join(tmp_dir, "workspace"))

    on_exit(fn ->
      if previous_workspace_root,
        do: System.put_env("SYNAPSIS_WORKSPACE_ROOT", previous_workspace_root),
        else: System.delete_env("SYNAPSIS_WORKSPACE_ROOT")
    end)

    {daemon, _task_supervisor} = start_test_daemon()
    %{daemon: daemon}
  end

  test "trigger creates heartbeat AgentRun and completes", %{tmp_dir: tmp_dir, daemon: daemon} do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: tmp_dir,
        scenario: :success,
        text: "heartbeat pulse ok"
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)

    assert {:ok, run} =
             trigger(daemon, "hb-success-1",
               prompt: "status check",
               assistant_name: harness.agent_name,
               provider: harness.provider.name,
               model: "characterization-model",
               idempotency_key: "hb-success-key-1",
               name: "pulse",
               tool_profile: "heartbeat",
               source: "scheduler"
             )

    assert run.kind == "heartbeat"
    assert run.tool_profile == "heartbeat"
    assert run.source == "scheduler"
    assert is_binary(run.id)

    assert_run_terminal(daemon, run.id, "completed", 20_000)

    GenServer.cast(daemon, {:heartbeat_outcome, :completed})
    Process.sleep(20)
    status = Daemon.status(daemon)
    assert %DateTime{} = status.last_heartbeat_success_at
    assert status.heartbeat_failure_streak == 0
  end

  test "provider failure yields failed run not completed", %{tmp_dir: tmp_dir, daemon: daemon} do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: tmp_dir,
        scenario: :provider_failure,
        text: "nope"
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)

    assert {:ok, run} =
             trigger(daemon, "hb-fail-1",
               prompt: "fail please",
               assistant_name: harness.agent_name,
               provider: harness.provider.name,
               model: "characterization-model",
               idempotency_key: "hb-fail-key-1"
             )

    assert_run_terminal(daemon, run.id, "failed", 20_000)
    GenServer.cast(daemon, {:heartbeat_outcome, :failed})
    Process.sleep(20)
    assert Daemon.status(daemon).heartbeat_failure_streak >= 1
  end

  test "deadline yields timed_out", %{tmp_dir: tmp_dir, daemon: daemon} do
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
             trigger(daemon, "hb-deadline-1",
               prompt: "deadline",
               assistant_name: harness.agent_name,
               provider: harness.provider.name,
               model: "characterization-model",
               idempotency_key: "hb-deadline-key-1",
               deadline_at: deadline
             )

    assert_run_terminal(daemon, run.id, "timed_out", 10_000)
    assert_receive {:provider_disconnected, _handler}, 1_000
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

  test "delivery failure does not rewrite completed execution", %{
    tmp_dir: tmp_dir,
    daemon: daemon
  } do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: tmp_dir,
        scenario: :success,
        text: "deliver me"
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)

    assert {:ok, run} =
             trigger(daemon, "hb-deliver-1",
               prompt: "deliver",
               assistant_name: harness.agent_name,
               provider: harness.provider.name,
               model: "characterization-model",
               idempotency_key: "hb-deliver-key-1"
             )

    assert_run_terminal(daemon, run.id, "completed", 20_000)
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

  test "idempotent heartbeat trigger returns same run", %{tmp_dir: tmp_dir, daemon: daemon} do
    harness = SessionHarness.setup_session!(tmp_dir: tmp_dir, scenario: :success, text: "idem")
    on_exit(fn -> SessionHarness.cleanup!(harness) end)
    key = "hb-idem-#{System.unique_integer([:positive])}"

    assert {:ok, first} =
             trigger(daemon, "hb-idem",
               prompt: "idem",
               assistant_name: harness.agent_name,
               provider: harness.provider.name,
               model: "characterization-model",
               idempotency_key: key
             )

    assert_run_terminal(daemon, first.id, "completed", 5_000)

    assert {:ok, second} =
             trigger(daemon, "hb-idem",
               prompt: "idem",
               assistant_name: harness.agent_name,
               provider: harness.provider.name,
               model: "characterization-model",
               idempotency_key: key
             )

    assert first.id == second.id

    wait_until(
      fn ->
        Daemon.status(daemon).active_count == 0 and Daemon.status(daemon).queued_count == 0
      end,
      5_000
    )
  end

  test "failure streak resets after success", %{daemon: daemon} do
    GenServer.cast(daemon, {:heartbeat_outcome, :failed})
    GenServer.cast(daemon, {:heartbeat_outcome, :failed})
    Process.sleep(20)
    assert Daemon.status(daemon).heartbeat_failure_streak >= 1

    GenServer.cast(daemon, {:heartbeat_outcome, :completed})
    Process.sleep(20)
    assert Daemon.status(daemon).heartbeat_failure_streak == 0
  end

  defp trigger(daemon, routine_id, opts) do
    opts = opts |> Map.new() |> Map.put(:heartbeat_id, routine_id)
    Daemon.trigger(daemon, :heartbeat, opts)
  end

  defp assert_run_terminal(daemon, run_id, status, timeout_ms) do
    wait_until(fn -> match?(%{status: ^status}, Runs.get(run_id)) end, timeout_ms)
    assert %{status: ^status} = Runs.get(run_id)
    # The next test clears the shared store. Do not erase durable state while
    # the daemon still owns a finalizer for this run.
    wait_until(fn -> Daemon.status(daemon).active_run_id != run_id end, timeout_ms)
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
