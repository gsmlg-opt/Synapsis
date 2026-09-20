defmodule Synapsis.Agent.DaemonTest do
  use Synapsis.Agent.DataCase, async: false

  alias Synapsis.Agent.Daemon
  alias Synapsis.Agent.RunSupervisor
  alias Synapsis.Agent.Runs
  alias Synapsis.Agent.TestSupport.SessionHarness

  @moduletag :tmp_dir

  setup do
    Synapsis.DataCase.clear_coord("coord/agent_runs/")
    Synapsis.DataCase.clear_coord("coord/agent_run_events/")
    Synapsis.DataCase.clear_coord("coord/agent_run_event_ids/")
    Synapsis.DataCase.clear_coord("coord/agent_run_idempotency/")
    :ok
  end

  test "status remains responsive" do
    status = Daemon.status()
    assert %DateTime{} = status.liveness_at
    assert is_list(status.active_run_ids)
    assert is_integer(status.active_count)
    assert is_integer(status.queued_count)
  end

  test "trigger kinds reserved for later tracks except heartbeat" do
    assert {:error, :not_implemented} = Daemon.trigger(:dream, "dream-1")
    assert {:error, :invalid_kind} = Daemon.trigger(:nope, nil)
  end

  test "trigger heartbeat requires prompt" do
    assert {:error, :missing_prompt} = Daemon.trigger(:heartbeat, "hb-missing")
  end

  test "submit forces read_only and is idempotent", %{tmp_dir: tmp_dir} do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: tmp_dir,
        scenario: :success,
        text: "daemon ok"
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)

    opts = [
      agent: harness.agent_name,
      provider: harness.provider.name,
      model: "characterization-model",
      idempotency_key: "idem-daemon-1",
      tool_profile: "dangerous"
    ]

    assert {:ok, run1} = Daemon.submit("hello daemon", opts)
    assert run1.tool_profile == "read_only"
    assert run1.kind == "manual"

    assert {:ok, run2} = Daemon.submit("hello daemon", opts)
    assert run2.id == run1.id

    assert_run_terminal(run1.id, "completed", 20_000)
  end

  test "two independent runs do not share coordinator state", %{tmp_dir: tmp_dir} do
    h1 =
      SessionHarness.setup_session!(
        tmp_dir: tmp_dir,
        agent_name: "daemon_a_#{System.unique_integer([:positive])}",
        scenario: :success,
        text: "run-a"
      )

    h2 =
      SessionHarness.setup_session!(
        tmp_dir: tmp_dir,
        agent_name: "daemon_b_#{System.unique_integer([:positive])}",
        scenario: :success,
        text: "run-b"
      )

    on_exit(fn ->
      SessionHarness.cleanup!(h1)
      SessionHarness.cleanup!(h2)
    end)

    assert {:ok, r1} =
             Daemon.submit("a",
               agent: h1.agent_name,
               provider: h1.provider.name,
               model: "characterization-model",
               idempotency_key: "par-a"
             )

    assert {:ok, r2} =
             Daemon.submit("b",
               agent: h2.agent_name,
               provider: h2.provider.name,
               model: "characterization-model",
               idempotency_key: "par-b"
             )

    assert r1.id != r2.id
    pid1 = RunSupervisor.whereis(r1.id)
    pid2 = RunSupervisor.whereis(r2.id)
    assert is_pid(pid1)
    assert is_pid(pid2)
    assert pid1 != pid2

    assert_run_terminal(r1.id, "completed", 20_000)
    assert_run_terminal(r2.id, "completed", 20_000)
  end

  test "cancel produces cancelled and cannot complete later", %{tmp_dir: tmp_dir} do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: tmp_dir,
        scenario: :hang,
        hang_ms: 5_000,
        text: "slow"
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)

    assert {:ok, run} =
             Daemon.submit("hang",
               agent: harness.agent_name,
               provider: harness.provider.name,
               model: "characterization-model",
               idempotency_key: "cancel-1"
             )

    wait_until(fn -> is_pid(RunSupervisor.whereis(run.id)) end, 5_000)

    wait_until(
      fn ->
        case Agent.get(harness.counter, & &1) do
          %{provider_requests: [_ | _]} -> true
          _ -> false
        end
      end,
      8_000
    )

    assert :ok = Daemon.cancel(run.id)
    assert_run_terminal(run.id, "cancelled", 10_000)

    final = Runs.get(run.id)
    assert final.status == "cancelled"
  end

  test "deadline produces timed_out", %{tmp_dir: tmp_dir} do
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
             Daemon.submit("deadline",
               agent: harness.agent_name,
               provider: harness.provider.name,
               model: "characterization-model",
               idempotency_key: "deadline-1",
               deadline_at: deadline
             )

    assert_run_terminal(run.id, "timed_out", 10_000)
  end

  test "coordinator crash is reconciled without completing", %{tmp_dir: tmp_dir} do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: tmp_dir,
        scenario: :hang,
        hang_ms: 5_000,
        text: "slow"
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)

    assert {:ok, run} =
             Daemon.submit("crash-me",
               agent: harness.agent_name,
               provider: harness.provider.name,
               model: "characterization-model",
               idempotency_key: "crash-1"
             )

    wait_until(fn -> is_pid(RunSupervisor.whereis(run.id)) end, 5_000)

    wait_until(
      fn ->
        case Agent.get(harness.counter, & &1) do
          %{provider_requests: [_ | _]} -> true
          _ -> false
        end
      end,
      8_000
    )

    pid = RunSupervisor.whereis(run.id)
    Process.exit(pid, :kill)

    wait_until(fn -> RunSupervisor.whereis(run.id) == nil end, 5_000)

    assert %{} = Daemon.status()
    assert {:ok, _status} = Daemon.reconcile()

    stored = Runs.get(run.id)
    assert stored.status in ~w(failed unknown_outcome timed_out)
    refute stored.status == "completed"
  end

  defp assert_run_terminal(run_id, status, timeout_ms) do
    wait_until(
      fn ->
        match?(%{status: ^status}, Runs.get(run_id))
      end,
      timeout_ms
    )

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
