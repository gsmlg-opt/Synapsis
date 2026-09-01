defmodule Synapsis.Agent.DaemonSubmissionCancelTest do
  use Synapsis.Agent.DaemonCase, async: false

  @tag :tmp_dir
  test "runs manual prompts in stable FIFO order without overlap", %{tmp_dir: tmp_dir} do
    {daemon, _task_supervisor} = start_test_daemon()
    owner = self()
    bypass = Bypass.open()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request_number = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      send(owner, {:provider_request, request_number, body, self()})

      if request_number == 1 do
        receive do
          :release_first_run -> :ok
        after
          5_000 -> raise "first run was not released"
        end
      end

      send_sse(conn, [text_chunk("result #{request_number}"), finish_chunk("stop")])
    end)

    {provider_name, agent_name} = register_provider_agent(tmp_dir, bypass)
    opts = daemon_opts(agent_name, provider_name)

    assert {:ok, first} = Daemon.submit(daemon, "first prompt", opts)
    assert_receive {:provider_request, 1, first_body, first_request_pid}, 2_000
    assert first_body =~ "first prompt"
    assert {:ok, first_running} = wait_for_run(first.id, "running")

    assert {:ok, second} = Daemon.submit(daemon, "second prompt", opts)
    assert {:ok, third} = Daemon.submit(daemon, "third prompt", opts)

    status = Daemon.status(daemon)
    assert %{active_run_id: first_id, queued_ids: [second_id, third_id]} = status

    assert first_id == first.id
    assert second_id == second.id
    assert third_id == third.id
    refute inspect(status) =~ "first prompt"
    refute_receive {:provider_request, 2, _body, _pid}, 200

    send(first_request_pid, :release_first_run)

    assert_receive {:provider_request, 2, second_body, _second_request_pid}, 2_000
    assert second_body =~ "second prompt"
    assert_receive {:provider_request, 3, third_body, _third_request_pid}, 2_000
    assert third_body =~ "third prompt"

    assert {:ok, first_completed} = wait_for_run(first.id, "completed")
    assert {:ok, second_completed} = wait_for_run(second.id, "completed")
    assert {:ok, third_completed} = wait_for_run(third.id, "completed")
    assert DateTime.compare(first_completed.finished_at, second_completed.started_at) != :gt
    assert DateTime.compare(second_completed.finished_at, third_completed.started_at) != :gt
    assert first_running.session_id == first_completed.session_id
  end

  @tag :tmp_dir
  test "cancelling a queued run removes it and prevents execution", %{tmp_dir: tmp_dir} do
    {daemon, _task_supervisor} = start_test_daemon()
    {provider_name, agent_name} = controlled_provider(tmp_dir)
    opts = daemon_opts(agent_name, provider_name)

    assert {:ok, first} = Daemon.submit(daemon, "hold first", opts)
    assert_receive {:provider_request, 1, _body, first_request_pid}, 2_000
    assert {:ok, _running} = wait_for_run(first.id, "running")
    assert {:ok, queued} = Daemon.submit(daemon, "never execute", opts)

    assert {:ok, cancelled} = Daemon.cancel(daemon, queued.id)
    assert cancelled.status == "cancelled"
    assert %{queued_ids: []} = Daemon.status(daemon)

    send(first_request_pid, :release_first_run)
    assert {:ok, _completed} = wait_for_run(first.id, "completed")
    refute_receive {:provider_request, 2, _body, _pid}, 300
    assert %{status: "cancelled"} = Runs.get(queued.id)
  end

  @tag :tmp_dir
  test "cancelling the active run cancels its session and drains once", %{tmp_dir: tmp_dir} do
    {daemon, _task_supervisor} = start_test_daemon()
    {provider_name, agent_name} = controlled_provider(tmp_dir)
    opts = daemon_opts(agent_name, provider_name)

    assert {:ok, active} = Daemon.submit(daemon, "cancel active", opts)
    assert_receive {:provider_request, 1, _body, first_request_pid}, 2_000
    assert {:ok, running} = wait_for_run(active.id, "running")
    assert :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{running.session_id}")

    assert {:ok, cancelled} = Daemon.cancel(daemon, active.id)
    assert cancelled.status == "cancelled"
    assert_receive {"session_status", %{status: "idle"}}, 2_000
    assert {:ok, %{status: "idle"}} = Synapsis.Sessions.get(running.session_id)
    assert %{active_run_id: nil, queued_count: 0} = Daemon.status(daemon)

    send(first_request_pid, :release_first_run)
  end

  test "cancel returns clear errors for unknown and terminal run ids" do
    {daemon, _task_supervisor} = start_test_daemon()

    assert {:error, :not_found} = Daemon.cancel(daemon, Ecto.UUID.generate())

    assert {:ok, run} =
             Runs.create(%{
               kind: "manual",
               status: "completed",
               source: "web",
               prompt: "already done",
               tool_profile: "read_only"
             })

    assert {:error, :terminal} = Daemon.cancel(daemon, run.id)
  end

  @tag :tmp_dir
  test "queue backpressure leaves no orphan queued run", %{tmp_dir: tmp_dir} do
    {daemon, _task_supervisor} = start_test_daemon(queue_capacity: 1)
    {provider_name, agent_name} = controlled_provider(tmp_dir)
    opts = daemon_opts(agent_name, provider_name)

    assert {:ok, first} = Daemon.submit(daemon, "first", opts)
    assert_receive {:provider_request, 1, _body, first_request_pid}, 2_000
    assert {:ok, _running} = wait_for_run(first.id, "running")
    assert {:ok, second} = Daemon.submit(daemon, "second", opts)
    assert {:error, :queue_full} = Daemon.submit(daemon, "rejected", opts)

    assert %{queued_ids: [second_id], queued_count: 1} = Daemon.status(daemon)
    assert second_id == second.id

    runs = Runs.list_recent(limit: 10)
    assert Enum.count(runs, &(&1.status == "queued")) == 1
    refute Enum.any?(runs, &(&1.prompt == "rejected" and &1.status == "queued"))

    assert {:ok, _cancelled} = Daemon.cancel(daemon, second.id)
    assert {:ok, _cancelled} = Daemon.cancel(daemon, first.id)
    send(first_request_pid, :release_first_run)
  end

  test "submission responds within the event bound when created-event append hangs forever" do
    Application.put_env(:synapsis_agent, :daemon_hanging_event, :append_run_created)
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :waiting)

    {daemon, _task_supervisor} =
      start_test_daemon(
        sessions: FakeSessions,
        run_events: HangingRunEvents,
        event_timeout: 50
      )

    assert :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, Daemon.topic())
    started_at = System.monotonic_time(:millisecond)
    submit_task = Task.async(fn -> Daemon.submit(daemon, "bounded created event", %{}) end)
    assert_receive {:hanging_event, :append_run_created, event_task, run_id}, 1_000

    assert_receive {:agent_daemon_event,
                    %{event: "agent.run.queued", run_id: ^run_id, status: "queued"}},
                   200

    result = Task.yield(submit_task, 500) || Task.shutdown(submit_task, :brutal_kill)

    assert {:ok, {:ok, run}} = result
    assert run.id == run_id
    refute Process.alive?(event_task)
    assert System.monotonic_time(:millisecond) - started_at < 500
    assert Daemon.status(daemon).last_error =~ "event_timeout"
  end

  test "runner task start failure retains the durable queued run" do
    assert {:ok, run} =
             Runs.create(%{
               kind: "manual",
               status: "queued",
               source: "web",
               prompt: "retain me",
               tool_profile: "read_only"
             })

    state = %{
      active_run: nil,
      queue: :queue.from_list([run]),
      cancelling_ids: MapSet.new(),
      task_supervisor: :missing_daemon_task_supervisor,
      deps: %{runs: Runs, run_events: Synapsis.Agent.RunEvents, sessions: Synapsis.Sessions},
      run_timeout: 100,
      last_error: nil,
      ready: true,
      recovery_error: nil,
      queue_capacity: 1,
      pending: %{}
    }

    assert {:noreply, retained} = Daemon.handle_info(:drain, state)
    assert [retained_run] = :queue.to_list(retained.queue)
    assert retained_run.id == run.id
    assert retained.active_run == nil
    assert retained.last_error =~ "run_task_start_failed"
    assert %{status: "queued"} = Runs.get(run.id)
  end

  test "submission persistence is serialized in call order" do
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :waiting)
    {daemon, _task_supervisor} = start_test_daemon(runs: SlowFirstRuns, sessions: FakeSessions)
    {:ok, first_attrs} = Synapsis.Agent.Daemon.Execution.manual_attrs("slow first", %{})
    {:ok, second_attrs} = Synapsis.Agent.Daemon.Execution.manual_attrs("fast second", %{})
    first_ref = make_ref()
    second_ref = make_ref()
    daemon_pid = Process.whereis(daemon)

    send(daemon_pid, {:"$gen_call", {self(), first_ref}, {:submit, first_attrs}})
    assert_receive {:slow_submit, slow_task}, 1_000
    send(daemon_pid, {:"$gen_call", {self(), second_ref}, {:submit, second_attrs}})
    refute_receive {:fast_submit, _result}, 100
    refute_receive {^second_ref, _result}, 100

    send(slow_task, :release_slow_submit)
    assert_receive {^first_ref, {:ok, first_run}}, 1_000
    assert_receive {:fast_submit, {:ok, fast_run}}, 1_000
    assert_receive {^second_ref, {:ok, second_run}}, 1_000
    assert second_run.id == fast_run.id
    assert_receive {:waiting_session, _session_id}, 1_000

    assert %{active_run_id: active_id, queued_ids: [queued_id]} = Daemon.status(daemon)
    assert active_id == first_run.id
    assert queued_id == second_run.id
  end

  test "outer run task cancels a blocked send and durably times out before draining" do
    {daemon, _task_supervisor} =
      start_test_daemon(sessions: BlockingSendSessions, run_timeout: 100)

    started_at = System.monotonic_time(:millisecond)
    assert {:ok, run} = Daemon.submit(daemon, "block send", %{})
    assert_receive {:blocking_send, runner, session_id}, 1_000
    assert Process.alive?(runner)

    assert_receive {:timeout_cancel, ^session_id}, 500

    assert {:ok, failed} =
             wait_for(
               fn ->
                 case Runs.get(run.id) do
                   %{status: "failed"} = failed -> {:ok, failed}
                   _other -> :retry
                 end
               end,
               700
             )

    assert failed.error =~ "session_timeout"
    assert failed.session_id == session_id
    refute Process.alive?(runner)
    assert System.monotonic_time(:millisecond) - started_at < 700
    assert %{active_run_id: nil} = Daemon.status(daemon)
    refute_receive {:timeout_cancel, ^session_id}, 150
  end

  test "mark_running failure retains and cancels the volatile created session" do
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :mark_running_failure)

    {daemon, _task_supervisor} =
      start_test_daemon(runs: MarkRunningFailRuns, sessions: FakeSessions)

    assert {:ok, run} = Daemon.submit(daemon, "fail after create", %{})
    assert_receive {:mark_running_failed, inner}, 1_000
    assert_receive {:session_cancelled, session_id}, 1_000
    assert {:ok, failed} = wait_for_run(run.id, "failed")
    assert failed.session_id == session_id
    assert failed.error =~ "mark_running_failed"
    refute Process.alive?(inner)
    assert %{active_run_id: nil} = Daemon.status(daemon)
  end

  test "durable active cancel drains despite session cleanup failure" do
    {daemon, _task_supervisor} = start_test_daemon(sessions: CleanupFailSessions)
    assert {:ok, run} = Daemon.submit(daemon, "cancel cleanup failure", %{})
    assert_receive {:cleanup_waiting, session_id}, 1_000
    assert {:ok, _running} = wait_for_run(run.id, "running")
    assert {:ok, second} = Daemon.submit(daemon, "runs after cleanup failure", %{})
    runner = :sys.get_state(Process.whereis(daemon)).active_run.task_pid

    assert {:ok, cancelled} = Daemon.cancel(daemon, run.id)
    assert cancelled.status == "cancelled"
    assert_receive {:cleanup_cancel, ^session_id}, 1_000
    refute Process.alive?(runner)
    assert %{last_error: error} = Daemon.status(daemon)
    assert error =~ "cleanup failure"
    assert String.length(error) <= 500

    assert_receive {:cleanup_waiting, _second_session_id}, 1_000
    assert {:ok, status} = wait_for_status(daemon, &(&1.active_run_id == second.id))
    assert status.queued_ids == []
  end

  test "durable active cancel drains when cancelled-event append hangs forever" do
    Application.put_env(:synapsis_agent, :daemon_hanging_event, :append_run_cancelled)
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :waiting)

    {daemon, _task_supervisor} =
      start_test_daemon(
        sessions: FakeSessions,
        run_events: HangingRunEvents,
        event_timeout: 50
      )

    assert {:ok, first} = Daemon.submit(daemon, "cancel with hung event", %{})
    assert_receive {:waiting_session, _first_session_id}, 1_000
    assert {:ok, second} = Daemon.submit(daemon, "drain after hung cancel event", %{})

    cancel_task = Task.async(fn -> Daemon.cancel(daemon, first.id) end)
    assert_receive {:hanging_event, :append_run_cancelled, event_task, first_id}, 1_000
    assert first_id == first.id
    result = Task.yield(cancel_task, 500) || Task.shutdown(cancel_task, :brutal_kill)

    assert {:ok, {:ok, %{status: "cancelled"}}} = result
    assert_receive {:waiting_session, _second_session_id}, 500
    refute Process.alive?(event_task)

    status = Daemon.status(daemon)
    assert status.active_run_id == second.id
    assert status.last_error =~ "event_timeout"
  end

  test "queued cancel responds when cancelled-event append hangs forever" do
    Application.put_env(:synapsis_agent, :daemon_hanging_event, :append_run_cancelled)
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :waiting)

    {daemon, _task_supervisor} =
      start_test_daemon(
        sessions: FakeSessions,
        run_events: HangingRunEvents,
        event_timeout: 50
      )

    assert {:ok, active} = Daemon.submit(daemon, "hold active for queued cancel", %{})
    assert_receive {:waiting_session, _session_id}, 1_000
    assert {:ok, queued} = Daemon.submit(daemon, "queued hung cancel event", %{})

    cancel_task = Task.async(fn -> Daemon.cancel(daemon, queued.id) end)
    assert_receive {:hanging_event, :append_run_cancelled, event_task, queued_id}, 1_000
    assert queued_id == queued.id
    result = Task.yield(cancel_task, 500) || Task.shutdown(cancel_task, :brutal_kill)

    assert {:ok, {:ok, %{status: "cancelled"}}} = result
    refute Process.alive?(event_task)
    assert %{active_run_id: active_id, queued_ids: [], last_error: error} = Daemon.status(daemon)
    assert active_id == active.id
    assert error =~ "event_timeout"
  end

  test "submit task death after create reconciles the pre-generated durable run" do
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :waiting)

    {daemon, _task_supervisor} =
      start_test_daemon(runs: KillAfterCreateRuns, sessions: FakeSessions)

    caller = Task.async(fn -> Daemon.submit(daemon, "reconcile created run", %{}) end)
    assert_receive {:submit_created, submit_task, created}, 1_000
    Process.exit(submit_task, :kill)

    assert {:ok, reconciled} = Task.await(caller, 2_000)
    assert reconciled.id == created.id
    assert_receive {:waiting_session, session_id}, 1_000
    assert {:ok, running} = wait_for_run(created.id, "running")
    assert running.session_id == session_id
    assert Daemon.status(daemon).active_run_id == created.id
  end

  test "submit and reconciliation task deaths plus transient reads preserve FIFO" do
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :waiting)
    {:ok, fault_agent} = Agent.start_link(fn -> 0 end)
    Application.put_env(:synapsis_agent, :daemon_reconcile_fault_agent, fault_agent)

    {daemon, _task_supervisor} =
      start_test_daemon(runs: ReconcileFaultRuns, sessions: FakeSessions)

    first_caller =
      Task.async(fn -> Daemon.submit(daemon, "reconcile with repeated faults", %{}) end)

    assert_receive {:submit_created, submit_task, created}, 1_000
    second_caller = Task.async(fn -> Daemon.submit(daemon, "later submission", %{}) end)
    Process.exit(submit_task, :kill)

    assert_receive {:reconcile_read, reconcile_task, run_id}, 1_000
    assert run_id == created.id
    refute_receive {:later_submit, _result}, 100
    Process.exit(reconcile_task, :kill)

    assert_receive {:reconcile_read_failed, ^run_id}, 1_000

    assert {:ok, reconciled} = Task.await(first_caller, 2_000)
    assert reconciled.id == created.id
    assert_receive {:later_submit, {:ok, later}}, 1_000
    assert {:ok, second} = Task.await(second_caller, 2_000)
    assert second.id == later.id

    assert_receive {:waiting_session, _session_id}, 1_000
    assert %{active_run_id: active_id, queued_ids: [queued_id]} = Daemon.status(daemon)
    assert active_id == created.id
    assert queued_id == later.id
    assert %{status: "running"} = Runs.get(created.id)
    assert %{status: "queued"} = Runs.get(later.id)
  end

  test "durable submit create and fetch timeouts reconcile the same FIFO head" do
    {:ok, deadline_agent} =
      Agent.start_link(fn -> %{create: :persist_then_hang, fetch: :hang} end)

    Application.put_env(:synapsis_agent, :daemon_deadline_agent, deadline_agent)
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :waiting)

    {daemon, _task_supervisor} =
      start_test_daemon(
        runs: DeadlineRuns,
        sessions: FakeSessions,
        operation_timeout: 50
      )

    first_caller = Task.async(fn -> Daemon.submit(daemon, "deadline first", %{}) end)
    assert_receive {:durable_operation_hung, :create_after_persist, create_task, created}, 1_000
    second_caller = Task.async(fn -> Daemon.submit(daemon, "deadline second", %{}) end)
    assert {:ok, :gone} = wait_for_task_exit(create_task)

    assert_receive {:durable_operation_hung, :fetch, fetch_task, run_id}, 1_000
    assert run_id == created.id
    assert %{ready: true} = Daemon.status(daemon)
    refute_receive {:durable_operation_called, :create, "deadline second"}, 100
    assert {:ok, :gone} = wait_for_task_exit(fetch_task)

    Agent.update(deadline_agent, &Map.merge(&1, %{create: :pass, fetch: :pass}))

    assert {:ok, first} = Task.await(first_caller, 2_000)
    assert first.id == created.id
    assert_receive {:durable_operation_called, :create, "deadline second"}, 1_000
    assert {:ok, second} = Task.await(second_caller, 2_000)
    assert_receive {:waiting_session, _session_id}, 1_000

    assert %{active_run_id: first_id, queued_ids: [second_id]} = Daemon.status(daemon)
    assert first_id == first.id
    assert second_id == second.id
  end

  test "durable cancel timeout retries until the caller gets one conclusive reply" do
    {:ok, deadline_agent} = Agent.start_link(fn -> %{cancel: :hang} end)
    Application.put_env(:synapsis_agent, :daemon_deadline_agent, deadline_agent)
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :waiting)

    {daemon, _task_supervisor} =
      start_test_daemon(
        runs: DeadlineRuns,
        sessions: FakeSessions,
        operation_timeout: 50
      )

    assert {:ok, active} = Daemon.submit(daemon, "hold during cancel deadline", %{})
    assert_receive {:waiting_session, _session_id}, 1_000
    assert {:ok, queued} = Daemon.submit(daemon, "cancel after deadline", %{})

    cancel_caller = Task.async(fn -> Daemon.cancel(daemon, queued.id) end)
    assert_receive {:durable_operation_hung, :cancel, cancel_task, _run}, 1_000
    assert %{active_run_id: active_id} = Daemon.status(daemon)
    assert active_id == active.id
    assert {:ok, :gone} = wait_for_task_exit(cancel_task)

    Agent.update(deadline_agent, &Map.put(&1, :cancel, :pass))
    assert {:ok, %{status: "cancelled"}} = Task.await(cancel_caller, 2_000)
    assert %{status: "cancelled"} = Runs.get(queued.id)
  end
end
