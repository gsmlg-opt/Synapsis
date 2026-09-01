defmodule Synapsis.Agent.DaemonSupervisionStatusTest do
  use Synapsis.Agent.DaemonCase, async: false

  test "daemon and run task supervisor restart together under a nested supervisor" do
    nested = Process.whereis(Synapsis.Agent.Daemon.Supervisor)
    runtime_registry = Process.whereis(Synapsis.Agent.Runtime.RunRegistry)
    daemon = Process.whereis(Daemon)
    task_supervisor = Process.whereis(Synapsis.Agent.Daemon.RunTaskSupervisor)

    assert Enum.any?(
             Supervisor.which_children(Synapsis.Agent.Supervisor),
             &match?(
               {Synapsis.Agent.Daemon.Supervisor, ^nested, :supervisor, _modules},
               &1
             )
           )

    assert {:ok, worker} =
             Task.Supervisor.start_child(Synapsis.Agent.Daemon.RunTaskSupervisor, fn ->
               receive do
                 :never -> :ok
               end
             end)

    Process.exit(daemon, :kill)

    assert {:ok, {new_daemon, new_task_supervisor}} =
             wait_for_daemon_pair(daemon, task_supervisor)

    refute Process.alive?(worker)
    assert Process.whereis(Synapsis.Agent.Runtime.RunRegistry) == runtime_registry
    assert Process.whereis(Synapsis.Agent.Daemon.Supervisor) == nested
    assert Process.alive?(new_daemon)
    assert Process.alive?(new_task_supervisor)
    assert {:ok, %{ready: true}} = wait_for_ready()
  end

  test "run task supervisor death also restarts daemon and reaps workers" do
    runtime_registry = Process.whereis(Synapsis.Agent.Runtime.RunRegistry)
    daemon = Process.whereis(Daemon)
    task_supervisor = Process.whereis(Synapsis.Agent.Daemon.RunTaskSupervisor)

    assert {:ok, worker} =
             Task.Supervisor.start_child(task_supervisor, fn ->
               receive do
                 :never -> :ok
               end
             end)

    Process.exit(task_supervisor, :kill)

    assert {:ok, {new_daemon, new_task_supervisor}} =
             wait_for_daemon_pair(daemon, task_supervisor)

    refute Process.alive?(worker)
    assert Process.whereis(Synapsis.Agent.Runtime.RunRegistry) == runtime_registry
    assert Process.alive?(new_daemon)
    assert Process.alive?(new_task_supervisor)
    assert {:ok, %{ready: true}} = wait_for_ready()
  end

  test "reports a ready empty state without exposing prompt data" do
    assert {:ok, status} = wait_for_ready()

    assert %{
             ready: true,
             active_run: nil,
             active_run_id: nil,
             queued_count: 0,
             queued_ids: [],
             last_error: nil,
             recovery_error: nil
           } = status

    refute Map.has_key?(status, :prompt)
  end

  test "rejects blank prompts and invalid options before persistence" do
    {daemon, _task_supervisor} = start_test_daemon()

    assert {:error, :invalid_prompt} = Daemon.submit(daemon, "  ", %{})
    assert {:error, :invalid_options} = Daemon.submit(daemon, "Do work", [])

    assert [] = Runs.list_recent()
    assert %{active_run_id: nil, queued_count: 0} = Daemon.status(daemon)
  end

  test "rejects non-positive and non-integer daemon timeouts at init" do
    {_daemon, task_supervisor} = start_test_daemon()
    Process.flag(:trap_exit, true)

    for {key, value} <- [
          run_timeout: -1,
          cleanup_timeout: -1,
          event_timeout: :infinity,
          operation_timeout: "slow"
        ] do
      name = String.to_atom("invalid_daemon_timeout_#{System.unique_integer([:positive])}")

      assert {:error, {:invalid_timeout, ^key}} =
               Daemon.start_link(
                 [name: name, task_supervisor: task_supervisor, recover?: false] ++ [{key, value}]
               )
    end
  end

  test "status stays responsive while submission persistence is blocked" do
    {daemon, _task_supervisor} = start_test_daemon(runs: BlockingRuns)
    submit_task = Task.async(fn -> Daemon.submit(daemon, "blocked submit", %{}) end)

    assert_receive {:blocking_store, store_task}, 1_000
    status_task = Task.async(fn -> Daemon.status(daemon) end)
    status_result = Task.yield(status_task, 200)
    send(store_task, :release_store)

    assert {:ok, %{ready: true}} = status_result
    assert {:ok, _run} = Task.await(submit_task, 2_000)
  end

  test "status publication coalesces dirty snapshots and preserves sequence order" do
    {:ok, status_agent} = Agent.start_link(fn -> %{attempt: 0, mode: :block} end)
    Application.put_env(:synapsis_agent, :daemon_status_agent, status_agent)

    {daemon, task_supervisor} =
      start_test_daemon(run_events: ControlledStatusRunEvents, event_timeout: 5_000)

    assert_receive {:status_publish_started, publisher, 1, first_sequence, first_status}, 1_000
    assert first_status.ready
    Agent.update(status_agent, &%{&1 | mode: :pass})

    daemon_pid = Process.whereis(daemon)
    Enum.each(1..5, fn _index -> send(daemon_pid, :status_changed) end)
    Process.sleep(100)
    assert Task.Supervisor.children(task_supervisor) == [publisher]

    send(publisher, :release_status)
    assert_receive {:status_published, 1, ^first_sequence, ^first_status}, 1_000
    assert_receive {:status_publish_started, _publisher, 2, latest_sequence, latest_status}, 1_000
    assert_receive {:status_published, 2, ^latest_sequence, ^latest_status}, 1_000
    assert latest_sequence > first_sequence
    assert latest_status == Daemon.status(daemon)
    refute_receive {:status_publish_started, _publisher, 3, _sequence, _status}, 100
  end

  test "hung status publication keeps at most one child and retries the latest snapshot" do
    {:ok, status_agent} = Agent.start_link(fn -> %{attempt: 0, mode: :hang} end)
    Application.put_env(:synapsis_agent, :daemon_status_agent, status_agent)

    {daemon, task_supervisor} =
      start_test_daemon(run_events: ControlledStatusRunEvents, event_timeout: 50)

    assert_receive {:status_publish_started, first, 1, first_sequence, _status}, 1_000
    daemon_pid = Process.whereis(daemon)
    Enum.each(1..5, fn _index -> send(daemon_pid, :status_changed) end)
    assert {:ok, :gone} = wait_for_task_exit(first)

    assert_receive {:status_publish_started, second, 2, second_sequence, _status}, 1_000
    assert Task.Supervisor.children(task_supervisor) == [second]
    assert second_sequence > first_sequence
    Agent.update(status_agent, &%{&1 | mode: :pass})
    assert {:ok, :gone} = wait_for_task_exit(second)

    assert_receive {:status_publish_started, third, 3, latest_sequence, latest_status}, 1_000
    assert_receive {:status_published, 3, ^latest_sequence, ^latest_status}, 1_000
    assert latest_sequence >= second_sequence
    assert latest_status == Daemon.status(daemon)
    assert {:ok, []} = wait_for_task_children(task_supervisor, [])
    refute Process.alive?(third)
  end

  test "fast status publication errors record a bound and retry after a delay" do
    {:ok, status_agent} = Agent.start_link(fn -> %{attempt: 0, mode: :error} end)
    Application.put_env(:synapsis_agent, :daemon_status_agent, status_agent)

    {daemon, _task_supervisor} =
      start_test_daemon(
        run_events: ControlledStatusRunEvents,
        status_retry_ms: 75
      )

    started_at = System.monotonic_time(:millisecond)
    assert_receive {:status_publish_started, _first, 1, _sequence, _status}, 1_000
    refute_receive {:status_publish_started, _publisher, 2, _sequence, _status}, 30
    Agent.update(status_agent, &%{&1 | mode: :pass})

    assert_receive {:status_publish_started, _second, 2, sequence, status}, 500
    assert_receive {:status_published, 2, ^sequence, ^status}, 500
    assert System.monotonic_time(:millisecond) - started_at >= 50

    publisher_state = :sys.get_state(Process.whereis(status_publisher_name(daemon)))
    assert publisher_state.last_error =~ "status_publish_failed"
  end

  test "a newer status supersedes an older delayed retry" do
    {:ok, status_agent} = Agent.start_link(fn -> %{attempt: 0, mode: :error} end)
    Application.put_env(:synapsis_agent, :daemon_status_agent, status_agent)

    {daemon, _task_supervisor} =
      start_test_daemon(
        run_events: ControlledStatusRunEvents,
        status_retry_ms: 5_000
      )

    assert_receive {:status_publish_started, _first, 1, first_sequence, first_status}, 1_000

    publisher = Process.whereis(status_publisher_name(daemon))

    assert {:ok, _state} =
             wait_for(fn ->
               state = :sys.get_state(publisher)

               if is_nil(state.current) and is_binary(state.last_error),
                 do: {:ok, state},
                 else: :retry
             end)

    Agent.update(status_agent, &%{&1 | mode: :block})
    send(Process.whereis(daemon), :status_changed)

    assert_receive {:status_publish_started, second, 2, second_sequence, second_status}, 1_000
    assert second_sequence > first_sequence

    send(publisher, {:retry, {first_sequence, first_status}})
    _state = :sys.get_state(publisher)

    Agent.update(status_agent, &%{&1 | mode: :pass})
    send(second, :release_status)

    assert_receive {:status_published, 2, ^second_sequence, ^second_status}, 1_000
    refute_receive {:status_publish_started, _worker, 3, ^first_sequence, ^first_status}, 100
  end

  test "status stays responsive while session cancellation is blocked" do
    {daemon, _task_supervisor} = start_test_daemon(sessions: BlockingCancelSessions)
    assert {:ok, run} = Daemon.submit(daemon, "wait for cancel", %{})
    assert_receive {:waiting_session, session_id}, 1_000
    assert {:ok, running} = wait_for_run(run.id, "running")
    assert running.session_id == session_id

    cancel_task = Task.async(fn -> Daemon.cancel(daemon, run.id) end)
    assert_receive {:blocking_session_cancel, cancel_worker, ^session_id}, 1_000
    status_task = Task.async(fn -> Daemon.status(daemon) end)
    status_result = Task.yield(status_task, 200)
    send(cancel_worker, :release_cancel)

    assert {:ok, %{active_run_id: run_id}} = status_result
    assert run_id == run.id
    assert {:ok, %{status: "cancelled"}} = Task.await(cancel_task, 2_000)
  end

  test "status stays responsive until terminal event append completes" do
    Application.put_env(:synapsis_agent, :daemon_block_event, :append_run_completed)
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :immediate_done)

    {daemon, _task_supervisor} =
      start_test_daemon(sessions: FakeSessions, run_events: BlockingRunEvents)

    assert {:ok, run} = Daemon.submit(daemon, "finish outside callback", %{})
    assert_receive {:blocking_event, :append_run_completed, event_task}, 1_000
    status_task = Task.async(fn -> Daemon.status(daemon) end)
    status_result = Task.yield(status_task, 200)
    send(event_task, :release_event)

    assert {:ok, %{active_run_id: run_id}} = status_result
    assert run_id == run.id
    assert {:ok, _completed} = wait_for_run(run.id, "completed")
    assert {:ok, %{active_run_id: nil}} = wait_for_status(daemon, &is_nil(&1.active_run_id))
  end

  test "bounds persisted, status, and event error text" do
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :huge_error)
    {daemon, _task_supervisor} = start_test_daemon(sessions: FakeSessions)
    assert :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, Daemon.topic())

    assert {:ok, run} = Daemon.submit(daemon, "bounded failure", %{})
    assert {:ok, failed} = wait_for_run(run.id, "failed")
    assert String.length(failed.error) == 500

    assert_receive {:agent_daemon_event,
                    %{
                      event: "agent.run.failed",
                      run_id: run_id,
                      payload: %{error: event_error}
                    }},
                   1_000

    assert run_id == run.id
    assert String.length(event_error) == 500
    assert {:ok, status} = wait_for_status(daemon, &is_nil(&1.active_run_id))
    assert String.length(status.last_error) == 500
  end
end
