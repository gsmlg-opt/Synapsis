defmodule Synapsis.Agent.DaemonExecutionTest do
  use Synapsis.Agent.DaemonCase, async: false

  @tag :tmp_dir
  test "runs a manual prompt through a real coding session and persists its summary", %{
    tmp_dir: tmp_dir
  } do
    {daemon, _task_supervisor} = start_test_daemon()
    {provider_name, agent_name} = register_text_provider(tmp_dir, "daemon complete")
    assert :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, Daemon.topic())

    assert {:ok, queued} =
             Daemon.submit(daemon, "Complete the manual run", %{
               assistant_name: agent_name,
               provider: provider_name,
               model: "daemon-test-model"
             })

    assert queued.kind == "manual"
    assert queued.status == "queued"

    assert_receive {:agent_daemon_event,
                    %{event: "agent.run.queued", run_id: run_id, status: "queued"}},
                   1_000

    assert run_id == queued.id

    assert {:ok, completed} =
             wait_for(fn ->
               case Runs.get(queued.id) do
                 %{status: "completed"} = run -> {:ok, run}
                 _other -> :retry
               end
             end)

    assert completed.session_id
    assert completed.summary == "daemon complete"
    assert {:ok, %{id: session_id}} = Synapsis.Sessions.get(completed.session_id)
    assert session_id == completed.session_id

    assert_receive {:agent_daemon_event,
                    %{event: "agent.run.started", run_id: ^run_id, status: "running"}},
                   1_000

    assert_receive {:agent_daemon_event,
                    %{
                      event: "agent.run.completed",
                      run_id: ^run_id,
                      status: "completed"
                    }},
                   1_000

    assert %{active_run_id: nil, queued_count: 0} = Daemon.status(daemon)
  end

  @tag :tmp_dir
  test "marks provider failures failed and remains ready", %{tmp_dir: tmp_dir} do
    {daemon, _task_supervisor} = start_test_daemon()
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(503, Jason.encode!(%{"error" => %{"message" => "offline"}}))
    end)

    {provider_name, agent_name} = register_provider_agent(tmp_dir, bypass)

    assert {:ok, queued} =
             Daemon.submit(daemon, "Fail this run", %{
               assistant_name: agent_name,
               provider: provider_name,
               model: "daemon-test-model"
             })

    assert {:ok, failed} = wait_for_run(queued.id, "failed")
    assert failed.error =~ "offline"

    assert {:ok, %{ready: true, active_run_id: nil, queued_count: 0}} =
             wait_for_status(daemon, &is_nil(&1.active_run_id))

    assert Process.alive?(Process.whereis(daemon))
  end

  @tag :tmp_dir
  test "an abnormal run task exit fails the run and the daemon drains", %{tmp_dir: tmp_dir} do
    {daemon, _task_supervisor} = start_test_daemon()
    {provider_name, agent_name} = controlled_provider(tmp_dir)

    assert {:ok, run} =
             Daemon.submit(daemon, "crash waiter", daemon_opts(agent_name, provider_name))

    assert_receive {:provider_request, 1, _body, request_pid}, 2_000
    assert {:ok, _running} = wait_for_run(run.id, "running")
    task_pid = :sys.get_state(Process.whereis(daemon)).active_run.task_pid
    Process.exit(task_pid, :kill)

    assert {:ok, failed} = wait_for_run(run.id, "failed")
    assert failed.error =~ "run task exited"
    assert %{ready: true, active_run_id: nil, queued_count: 0} = Daemon.status(daemon)
    assert Process.alive?(Process.whereis(daemon))

    send(request_pid, :release_first_run)
  end

  test "durable completion drains when completed-event append hangs forever" do
    Application.put_env(:synapsis_agent, :daemon_hanging_event, :append_run_completed)
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :controlled_done)

    {daemon, _task_supervisor} =
      start_test_daemon(
        sessions: FakeSessions,
        run_events: HangingRunEvents,
        event_timeout: 50
      )

    assert :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, Daemon.topic())
    assert {:ok, first} = Daemon.submit(daemon, "hung terminal event", %{})
    assert_receive {:controlled_session, first_inner, _session_id}, 1_000
    assert {:ok, second} = Daemon.submit(daemon, "drain after hung terminal event", %{})
    send(first_inner, :complete_session)

    assert_receive {:hanging_event, :append_run_completed, event_task, first_id}, 1_000
    assert first_id == first.id

    assert_receive {:agent_daemon_event,
                    %{event: "agent.run.completed", run_id: ^first_id, status: "completed"}},
                   200

    assert {:ok, _completed} = wait_for_run(first.id, "completed")
    assert_receive {:controlled_session, second_inner, _session_id}, 500
    refute Process.alive?(event_task)

    status = Daemon.status(daemon)
    assert status.active_run_id == second.id
    assert status.last_error =~ "event_timeout"
    send(second_inner, :complete_session)
  end

  test "hung started-event child dies with its killed run owner" do
    Application.put_env(:synapsis_agent, :daemon_hanging_event, :append_run_started)

    {daemon, task_supervisor} =
      start_test_daemon(
        sessions: FakeSessions,
        run_events: HangingRunEvents,
        event_timeout: 5_000
      )

    assert :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, Daemon.topic())
    assert {:ok, run} = Daemon.submit(daemon, "kill owner during started event", %{})
    assert_receive {:hanging_event, :append_run_started, event_task, run_id}, 1_000
    assert run_id == run.id

    assert_receive {:agent_daemon_event,
                    %{event: "agent.run.started", run_id: ^run_id, status: "running"}},
                   200

    assert event_task in Task.Supervisor.children(task_supervisor)

    outer = :sys.get_state(Process.whereis(daemon)).active_run.task_pid
    Process.exit(outer, :kill)

    assert {:ok, _failed} = wait_for_run(run.id, "failed")
    assert {:ok, :gone} = wait_for_task_exit(event_task)
    refute event_task in Task.Supervisor.children(task_supervisor)

    assert {:ok, %{ready: true, active_run_id: nil}} =
             wait_for_status(daemon, &is_nil(&1.active_run_id))
  end

  test "hung terminal-event child dies with its killed finalizer owner" do
    Application.put_env(:synapsis_agent, :daemon_hanging_event, :append_run_completed)
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :controlled_done)

    {daemon, task_supervisor} =
      start_test_daemon(
        sessions: FakeSessions,
        run_events: HangingRunEvents,
        event_timeout: 5_000
      )

    assert {:ok, run} = Daemon.submit(daemon, "kill owner during terminal event", %{})
    assert_receive {:controlled_session, inner, _session_id}, 1_000
    send(inner, :complete_session)
    assert_receive {:hanging_event, :append_run_completed, event_task, run_id}, 1_000
    assert run_id == run.id
    assert event_task in Task.Supervisor.children(task_supervisor)
    assert %{status: "completed"} = Runs.get(run.id)

    outer = :sys.get_state(Process.whereis(daemon)).active_run.task_pid
    Process.exit(outer, :kill)

    assert {:ok, :gone} = wait_for_task_exit(event_task)
    refute event_task in Task.Supervisor.children(task_supervisor)

    assert {:ok, %{ready: true, active_run_id: nil}} =
             wait_for_status(daemon, &is_nil(&1.active_run_id))

    assert %{status: "completed"} = Runs.get(run.id)
  end

  test "chatty session events do not reset the absolute run timeout" do
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :chatty)
    {daemon, _task_supervisor} = start_test_daemon(sessions: FakeSessions, run_timeout: 100)
    started_at = System.monotonic_time(:millisecond)

    assert {:ok, run} = Daemon.submit(daemon, "time out absolutely", %{})
    assert {:ok, failed} = wait_for_run(run.id, "failed")

    assert failed.error =~ "session_timeout"
    assert System.monotonic_time(:millisecond) - started_at < 500
  end

  test "absolute run timeout includes time spent sending the prompt" do
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :delayed_done)
    {daemon, _task_supervisor} = start_test_daemon(sessions: FakeSessions, run_timeout: 50)

    assert {:ok, run} = Daemon.submit(daemon, "slow send", %{})
    assert {:ok, failed} = wait_for_run(run.id, "failed")
    assert failed.error =~ "session_timeout"
  end

  test "completion at the absolute deadline has one terminal CAS and never crashes the daemon" do
    previous_adapter = Application.get_env(:synapsis_agent, :agent_runs_kv_adapter, :missing)
    Application.put_env(:synapsis_agent, :agent_runs_kv_adapter, TerminalCountingKV)
    on_exit(fn -> restore_application_env(:agent_runs_kv_adapter, previous_adapter) end)
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :immediate_done)

    {daemon, _task_supervisor} = start_test_daemon(sessions: FakeSessions, run_timeout: 0)
    daemon_pid = Process.whereis(daemon)
    assert {:ok, run} = Daemon.submit(daemon, "deadline completion race", %{})

    assert {:ok, terminal} =
             wait_for(fn ->
               case Runs.get(run.id) do
                 %{status: status} = terminal when status in ~w(completed failed) ->
                   {:ok, terminal}

                 _other ->
                   :retry
               end
             end)

    assert_receive {:terminal_cas, key, terminal_status}, 1_000
    assert String.ends_with?(key, run.id)
    assert terminal_status == terminal.status
    refute_receive {:terminal_cas, ^key, _losing_status}, 150
    assert Process.whereis(daemon) == daemon_pid
    assert Process.alive?(daemon_pid)
    assert {:ok, %{active_run_id: nil}} = wait_for_status(daemon, &is_nil(&1.active_run_id))
  end

  test "terminal persistence failure retains degraded active ownership and does not drain" do
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :controlled_done)
    previous_adapter = Application.get_env(:synapsis_agent, :agent_runs_kv_adapter, :missing)
    Application.put_env(:synapsis_agent, :agent_runs_kv_adapter, SelectivePutIfKV)
    on_exit(fn -> restore_application_env(:agent_runs_kv_adapter, previous_adapter) end)

    {daemon, _task_supervisor} = start_test_daemon(sessions: FakeSessions)
    assert {:ok, first} = Daemon.submit(daemon, "cannot finalize", %{})
    assert_receive {:controlled_session, runner, _session_id}, 1_000
    assert {:ok, _running} = wait_for_run(first.id, "running")

    Application.put_env(
      :synapsis_agent,
      :daemon_selective_put_if,
      [{first.id, "completed"}]
    )

    send(runner, :complete_session)

    assert {:ok, status} =
             wait_for_status(daemon, fn status ->
               status.active_run_id == first.id and status.active_run.degraded == true
             end)

    assert status.last_error =~ "store failure"
    assert String.length(status.last_error) <= 500
    assert %{status: "running"} = Runs.get(first.id)

    assert {:ok, second} = Daemon.submit(daemon, "must remain queued", %{})
    assert %{active_run_id: first_id, queued_ids: [second_id]} = Daemon.status(daemon)
    assert first_id == first.id
    assert second_id == second.id
    assert %{status: "queued"} = Runs.get(second.id)
  end

  test "rejects oversized option fields and bounds volatile errors" do
    {daemon, _task_supervisor} = start_test_daemon()
    oversized = String.duplicate("x", 256)

    for field <- ~w(assistant_name provider model source tool_profile)a do
      assert {:error, :invalid_options} =
               Daemon.submit(daemon, "bounded", %{field => oversized})
    end

    assert [] = Runs.list_recent()
  end

  test "hung timeout cleanup cannot delay inner termination or durable failure" do
    {daemon, _task_supervisor} =
      start_test_daemon(
        sessions: HangingTimeoutCleanupSessions,
        run_timeout: 50,
        cleanup_timeout: 50
      )

    started_at = System.monotonic_time(:millisecond)
    assert {:ok, run} = Daemon.submit(daemon, "bounded timeout cleanup", %{})
    assert_receive {:timeout_inner_blocked, inner, session_id}, 1_000
    assert_receive {:timeout_cleanup_blocked, cleanup, ^session_id}, 500

    assert {:ok, failed} = wait_for_run(run.id, "failed")
    assert failed.error =~ "session_timeout"
    assert failed.session_id == session_id
    refute Process.alive?(inner)
    refute Process.alive?(cleanup)
    assert System.monotonic_time(:millisecond) - started_at < 500

    assert {:ok, status} = wait_for_status(daemon, &is_nil(&1.active_run_id))
    assert status.last_error =~ "cleanup_timeout"
  end

  test "hung cleanup child dies with its killed outer owner" do
    {:ok, cleanup_agent} = Agent.start_link(fn -> 0 end)
    Application.put_env(:synapsis_agent, :daemon_cleanup_call_agent, cleanup_agent)

    {daemon, task_supervisor} =
      start_test_daemon(
        sessions: FirstCleanupHangsSessions,
        run_timeout: 50,
        cleanup_timeout: 5_000
      )

    assert {:ok, run} = Daemon.submit(daemon, "kill owner during cleanup", %{})
    assert_receive {:owner_death_inner, _inner, session_id}, 1_000
    assert_receive {:owner_death_cleanup, cleanup_task, ^session_id}, 500
    assert cleanup_task in Task.Supervisor.children(task_supervisor)

    outer = :sys.get_state(Process.whereis(daemon)).active_run.task_pid
    Process.exit(outer, :kill)

    assert {:ok, _failed} = wait_for_run(run.id, "failed")
    assert {:ok, :gone} = wait_for_task_exit(cleanup_task)
    refute cleanup_task in Task.Supervisor.children(task_supervisor)

    assert {:ok, %{ready: true, active_run_id: nil}} =
             wait_for_status(daemon, &is_nil(&1.active_run_id))
  end

  test "durable completion drains even when terminal event append fails" do
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :controlled_done)

    {daemon, _task_supervisor} =
      start_test_daemon(sessions: FakeSessions, run_events: FailingTerminalRunEvents)

    assert {:ok, first} = Daemon.submit(daemon, "first terminal event failure", %{})
    assert_receive {:controlled_session, first_runner, _session_id}, 1_000
    assert {:ok, second} = Daemon.submit(daemon, "second still drains", %{})
    send(first_runner, :complete_session)

    assert {:ok, _completed} = wait_for_run(first.id, "completed")
    assert_receive {:controlled_session, second_runner, _session_id}, 1_000

    status = Daemon.status(daemon)
    assert status.active_run_id == second.id
    assert status.last_error =~ "terminal event failure"
    assert String.length(status.last_error) <= 500
    send(second_runner, :complete_session)
  end

  test "terminal put_if timeout retries the same completion intent" do
    previous_adapter = Application.get_env(:synapsis_agent, :agent_runs_kv_adapter, :missing)
    Application.put_env(:synapsis_agent, :agent_runs_kv_adapter, DeadlinePutIfKV)
    on_exit(fn -> restore_application_env(:agent_runs_kv_adapter, previous_adapter) end)

    {:ok, deadline_agent} =
      Agent.start_link(fn -> %{hang_put_if: MapSet.new(["completed"])} end)

    Application.put_env(:synapsis_agent, :daemon_deadline_agent, deadline_agent)
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :controlled_done)

    {daemon, _task_supervisor} =
      start_test_daemon(
        sessions: FakeSessions,
        operation_timeout: 50
      )

    assert {:ok, run} = Daemon.submit(daemon, "retry terminal put_if", %{})
    assert_receive {:controlled_session, inner, _session_id}, 1_000
    send(inner, :complete_session)
    assert_receive {:durable_operation_hung, {:put_if, "completed"}, terminal_task, _key}, 1_000
    assert %{active_run_id: run_id} = Daemon.status(daemon)
    assert run_id == run.id
    assert {:ok, :gone} = wait_for_task_exit(terminal_task)

    Agent.update(deadline_agent, &Map.put(&1, :hang_put_if, MapSet.new()))
    assert {:ok, completed} = wait_for_run(run.id, "completed")
    assert completed.summary == "(no assistant response)"
    assert {:ok, %{active_run_id: nil}} = wait_for_status(daemon, &is_nil(&1.active_run_id))
  end
end
