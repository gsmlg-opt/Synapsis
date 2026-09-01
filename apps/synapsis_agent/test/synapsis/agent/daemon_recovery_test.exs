defmodule Synapsis.Agent.DaemonRecoveryTest do
  use Synapsis.Agent.DaemonCase, async: false

  @tag :tmp_dir
  test "restart interrupts an executing run without replaying its prompt", %{tmp_dir: tmp_dir} do
    owner = self()
    bypass = Bypass.open()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
      request_number = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      send(owner, {:provider_request, request_number, self()})

      receive do
        :release_restart_run ->
          send_sse(conn, [text_chunk("late result"), finish_chunk("stop")])
      after
        5_000 -> Plug.Conn.send_resp(conn, 500, "timed out")
      end
    end)

    {provider_name, agent_name} = register_provider_agent(tmp_dir, bypass)
    opts = daemon_opts(agent_name, provider_name)

    assert {:ok, run} = Daemon.submit("possibly executing", opts)
    assert_receive {:provider_request, 1, request_pid}, 2_000
    assert {:ok, running} = wait_for_run(run.id, "running")

    daemon_pid = Process.whereis(Daemon)
    task_supervisor_pid = Process.whereis(Synapsis.Agent.Daemon.RunTaskSupervisor)
    Process.exit(daemon_pid, :kill)

    assert {:ok, restarted_pid} =
             wait_for(fn ->
               case Process.whereis(Daemon) do
                 pid when is_pid(pid) and pid != daemon_pid -> {:ok, pid}
                 _other -> :retry
               end
             end)

    assert Process.alive?(restarted_pid)

    assert {:ok, _new_task_supervisor_pid} =
             wait_for(fn ->
               case Process.whereis(Synapsis.Agent.Daemon.RunTaskSupervisor) do
                 pid when is_pid(pid) and pid != task_supervisor_pid -> {:ok, pid}
                 _other -> :retry
               end
             end)

    assert {:ok, interrupted} = wait_for_run(run.id, "interrupted")
    assert interrupted.session_id == running.session_id
    assert interrupted.metadata["interruption_reason"] == "daemon_restarted"
    refute_receive {:provider_request, 2, _request_pid}, 300
    assert Agent.get(counter, & &1) == 1

    send(request_pid, :release_restart_run)
  end

  test "recovery store errors remain visible without crash-looping" do
    previous = Application.get_env(:synapsis_agent, :agent_runs_kv_adapter, :missing)
    Application.put_env(:synapsis_agent, :agent_runs_kv_adapter, ScanFailingKV)

    on_exit(fn -> restore_application_env(:agent_runs_kv_adapter, previous) end)

    {daemon, _task_supervisor} = start_test_daemon(recover?: true)

    assert {:ok, status} =
             wait_for(fn ->
               case Daemon.status(daemon) do
                 %{ready: false, recovery_error: error} = status when is_binary(error) ->
                   {:ok, status}

                 _other ->
                   :retry
               end
             end)

    assert status.recovery_error =~ "store_unavailable"
    assert Process.alive?(Process.whereis(daemon))

    restore_application_env(:agent_runs_kv_adapter, previous)
    assert {:ok, recovered} = wait_for_status(daemon, & &1.ready)
    assert recovered.recovery_error == nil
  end

  test "all recovery scan and interrupt failures keep readiness false until retry succeeds" do
    attrs = %{
      kind: "manual",
      source: "web",
      prompt: "recover staged fault",
      tool_profile: "read_only"
    }

    assert {:ok, running} = Runs.create(Map.put(attrs, :status, "queued"))
    assert {:ok, running} = Runs.mark_running(running)
    assert {:ok, waiting} = Runs.create(Map.put(attrs, :status, "queued"))
    assert {:ok, waiting} = Runs.mark_running(waiting)
    assert {:ok, waiting} = Runs.mark_waiting_approval(waiting)
    assert {:ok, queued} = Runs.create(Map.put(attrs, :status, "queued"))

    {:ok, fault_agent} =
      Agent.start_link(fn ->
        %{
          scan: %{"running" => 1, "waiting_approval" => 1, "queued" => 1},
          interrupt: %{running.id => 1}
        }
      end)

    Application.put_env(:synapsis_agent, :daemon_recovery_fault_agent, fault_agent)
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :waiting)

    {daemon, _task_supervisor} =
      start_test_daemon(recover?: true, runs: RecoveryFaultRuns, sessions: FakeSessions)

    for status <- ~w(running waiting_approval queued) do
      assert_receive {:scan_failed, ^status}, 1_000
    end

    assert {:error, :not_ready} = Daemon.submit(daemon, "must wait for scans", %{})
    assert {:ok, %{ready: false}} = wait_for_status(daemon, &(not &1.ready))

    assert_receive {:interrupt_failed, running_id}, 1_000
    assert running_id == running.id
    assert {:ok, %{ready: false}} = wait_for_status(daemon, &(not &1.ready))
    assert {:ok, _interrupted} = wait_for_run(waiting.id, "interrupted")

    assert_receive {:waiting_session, _session_id}, 2_000

    assert {:ok, status} =
             wait_for_status(daemon, fn status ->
               status.ready and status.active_run_id == queued.id
             end)

    assert status.recovery_error == nil
    assert %{status: "interrupted"} = Runs.get(running.id)
    assert Process.alive?(Process.whereis(daemon))
  end

  test "recovery becomes ready after a durable interruption event append hangs forever" do
    attrs = %{
      kind: "manual",
      source: "web",
      prompt: "recover after hung interruption event",
      tool_profile: "read_only"
    }

    assert {:ok, running} = Runs.create(Map.put(attrs, :status, "queued"))
    assert {:ok, running} = Runs.mark_running(running)
    assert {:ok, queued} = Runs.create(Map.put(attrs, :status, "queued"))

    Application.put_env(:synapsis_agent, :daemon_hanging_event, :append_run_interrupted)
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :waiting)

    {daemon, _task_supervisor} =
      start_test_daemon(
        recover?: true,
        sessions: FakeSessions,
        run_events: HangingRunEvents,
        event_timeout: 50
      )

    assert_receive {:hanging_event, :append_run_interrupted, event_task, running_id}, 1_000
    assert running_id == running.id
    assert_receive {:waiting_session, _session_id}, 500

    assert {:ok, status} =
             wait_for_status(daemon, fn status ->
               status.ready and status.active_run_id == queued.id
             end)

    assert %{status: "interrupted"} = Runs.get(running.id)
    refute Process.alive?(event_task)
    assert status.last_error =~ "event_timeout"
  end

  @tag :tmp_dir
  test "recovery resumes never-started queued runs oldest first", %{tmp_dir: tmp_dir} do
    owner = self()
    bypass = Bypass.open()

    Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:recovered_provider_request, body})
      send_sse(conn, [text_chunk("recovered"), finish_chunk("stop")])
    end)

    {provider_name, agent_name} = register_provider_agent(tmp_dir, bypass)

    attrs = %{
      kind: "manual",
      status: "queued",
      source: "web",
      assistant_name: agent_name,
      provider: provider_name,
      model: "daemon-test-model",
      tool_profile: "read_only"
    }

    assert {:ok, first} = Runs.create(Map.put(attrs, :prompt, "recover first"))
    assert {:ok, second} = Runs.create(Map.put(attrs, :prompt, "recover second"))

    {daemon, _task_supervisor} = start_test_daemon(recover?: true)

    assert_receive {:recovered_provider_request, first_body}, 2_000
    assert first_body =~ "recover first"
    assert_receive {:recovered_provider_request, second_body}, 2_000
    assert second_body =~ "recover second"
    assert {:ok, _completed} = wait_for_run(first.id, "completed")
    assert {:ok, _completed} = wait_for_run(second.id, "completed")
    assert %{ready: true, active_run_id: nil, queued_count: 0} = Daemon.status(daemon)
  end

  test "partial recovery still interrupts waiting runs and owns every queued run" do
    previous_adapter = Application.get_env(:synapsis_agent, :agent_runs_kv_adapter, :missing)
    Application.put_env(:synapsis_agent, :agent_runs_kv_adapter, SelectivePutIfKV)
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :waiting)
    on_exit(fn -> restore_application_env(:agent_runs_kv_adapter, previous_adapter) end)

    attrs = %{
      kind: "manual",
      source: "web",
      prompt: "recover",
      tool_profile: "read_only"
    }

    assert {:ok, running} = Runs.create(Map.put(attrs, :status, "queued"))
    assert {:ok, running} = Runs.mark_running(running)
    assert {:ok, waiting} = Runs.create(Map.put(attrs, :status, "queued"))
    assert {:ok, waiting} = Runs.mark_running(waiting)
    assert {:ok, waiting} = Runs.mark_waiting_approval(waiting)
    assert {:ok, queued} = Runs.create(Map.put(attrs, :status, "queued"))

    Application.put_env(
      :synapsis_agent,
      :daemon_selective_put_if,
      [{running.id, "interrupted"}]
    )

    {daemon, _task_supervisor} =
      start_test_daemon(recover?: true, sessions: FakeSessions, queue_capacity: 1)

    assert {:ok, blocked} =
             wait_for_status(daemon, fn status ->
               not status.ready and is_binary(status.recovery_error)
             end)

    assert blocked.recovery_error =~ "store failure"
    assert %{status: "running"} = Runs.get(running.id)
    assert %{status: "interrupted"} = Runs.get(waiting.id)

    Application.put_env(:synapsis_agent, :daemon_selective_put_if, [])
    assert_receive {:waiting_session, _session_id}, 2_000

    assert {:ok, status} =
             wait_for_status(daemon, fn status ->
               status.ready and status.active_run_id == queued.id
             end)

    assert status.recovery_error == nil
    assert %{status: "interrupted"} = Runs.get(running.id)
    assert %{status: "running"} = Runs.get(queued.id)
  end

  test "recovery owns queued overflow instead of dropping durable runs" do
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :ordered)

    attrs = %{
      kind: "manual",
      status: "queued",
      source: "web",
      prompt: "overflow",
      tool_profile: "read_only"
    }

    assert {:ok, first} = Runs.create(Map.put(attrs, :prompt, "first"))
    assert {:ok, second} = Runs.create(Map.put(attrs, :prompt, "second"))
    assert {:ok, third} = Runs.create(Map.put(attrs, :prompt, "third"))

    {daemon, _task_supervisor} =
      start_test_daemon(recover?: true, sessions: FakeSessions, queue_capacity: 1)

    assert_receive {:ordered_session, "first", first_runner, _session_id}, 1_000

    assert {:ok, status} =
             wait_for_status(daemon, fn status ->
               status.active_run_id == first.id and status.queued_count == 1
             end)

    assert status.queued_ids == [second.id]
    assert status.recovery_backlog_count == 1
    assert {:error, :queue_full} = Daemon.submit(daemon, "new work", %{})

    send(first_runner, :complete_ordered)
    assert_receive {:ordered_session, "second", second_runner, _session_id}, 2_000
    assert length(Daemon.status(daemon).queued_ids) <= 1
    send(second_runner, :complete_ordered)
    assert_receive {:ordered_session, "third", third_runner, _session_id}, 2_000
    assert length(Daemon.status(daemon).queued_ids) <= 1
    send(third_runner, :complete_ordered)

    assert {:ok, _completed} = wait_for_run(first.id, "completed")
    assert {:ok, _completed} = wait_for_run(second.id, "completed")
    assert {:ok, _completed} = wait_for_run(third.id, "completed")

    assert {:ok, %{queued_ids: [], recovery_backlog_count: 0}} =
             wait_for_status(daemon, &is_nil(&1.active_run_id))
  end

  test "recovery backlog rejects newer work while a free slot is being refilled" do
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :ordered)
    {:ok, scan_agent} = Agent.start_link(fn -> 0 end)
    Application.put_env(:synapsis_agent, :daemon_refill_scan_agent, scan_agent)

    attrs = %{
      kind: "manual",
      status: "queued",
      source: "web",
      prompt: "backlog",
      tool_profile: "read_only"
    }

    assert {:ok, _first} = Runs.create(Map.put(attrs, :prompt, "backlog first"))
    assert {:ok, second} = Runs.create(Map.put(attrs, :prompt, "backlog second"))
    assert {:ok, third} = Runs.create(Map.put(attrs, :prompt, "backlog third"))

    {daemon, _task_supervisor} =
      start_test_daemon(
        recover?: true,
        runs: BlockingRefillRuns,
        sessions: FakeSessions,
        queue_capacity: 1
      )

    assert_receive {:ordered_session, "backlog first", first_inner, _session_id}, 1_000
    assert_receive {:refill_scan, refill_task}, 1_000
    assert %{queued_ids: [], recovery_backlog_count: 2} = Daemon.status(daemon)
    assert {:error, :queue_full} = Daemon.submit(daemon, "newer work", %{})
    refute Enum.any?(Runs.list_recent(limit: 10), &(&1.prompt == "newer work"))

    send(refill_task, :release_refill)

    assert {:ok, loaded} = wait_for_status(daemon, &(&1.queued_ids == [second.id]))
    assert length(loaded.queued_ids) <= 1
    send(first_inner, :complete_ordered)

    assert_receive {:ordered_session, "backlog second", second_inner, _session_id}, 2_000
    assert length(Daemon.status(daemon).queued_ids) <= 1
    send(second_inner, :complete_ordered)

    assert_receive {:ordered_session, "backlog third", third_inner, _session_id}, 2_000
    assert length(Daemon.status(daemon).queued_ids) <= 1
    send(third_inner, :complete_ordered)
    assert {:ok, _completed} = wait_for_run(third.id, "completed")
  end

  test "recovery operation timeout stays responsive and becomes ready after scan unblocks" do
    attrs = %{
      kind: "manual",
      status: "queued",
      source: "web",
      prompt: "recover after operation deadline",
      tool_profile: "read_only"
    }

    assert {:ok, queued} = Runs.create(attrs)
    {:ok, deadline_agent} = Agent.start_link(fn -> %{{:scan, "running"} => :hang} end)
    Application.put_env(:synapsis_agent, :daemon_deadline_agent, deadline_agent)
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :waiting)

    {daemon, _task_supervisor} =
      start_test_daemon(
        recover?: true,
        runs: DeadlineRuns,
        sessions: FakeSessions,
        operation_timeout: 50
      )

    assert_receive {:durable_operation_hung, {:scan, "running"}, scan_task, _status}, 1_000
    assert %{ready: false} = Daemon.status(daemon)
    assert {:ok, :gone} = wait_for_task_exit(scan_task)
    Agent.update(deadline_agent, &Map.put(&1, {:scan, "running"}, :pass))

    assert_receive {:waiting_session, _session_id}, 2_000

    assert {:ok, %{ready: true, active_run_id: active_id}} =
             wait_for_status(daemon, &(&1.ready and &1.active_run_id == queued.id))

    assert active_id == queued.id
  end
end
