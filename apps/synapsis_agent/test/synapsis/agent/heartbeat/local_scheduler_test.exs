defmodule Synapsis.Agent.Heartbeat.LocalSchedulerTest do
  use Synapsis.Agent.DaemonCase, async: false

  alias Synapsis.Agent.Heartbeat.LocalScheduler

  setup do
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :waiting)
    :ok
  end

  test "loads only enabled routines and routes a due heartbeat through the daemon" do
    {daemon, task_supervisor} = start_test_daemon(sessions: FakeSessions)
    heartbeat_id = Ecto.UUID.generate()

    configs = [
      heartbeat(heartbeat_id, "enabled"),
      heartbeat(Ecto.UUID.generate(), "disabled", enabled: false)
    ]

    scheduler = start_scheduler(configs, daemon, task_supervisor)
    assert [%{name: "enabled", next_run_at: %DateTime{}}] = LocalScheduler.status(scheduler)

    %{timers: %{"enabled" => %{token: token}}} = :sys.get_state(scheduler)
    send(scheduler, {:fire, "enabled", token})

    assert_receive {:waiting_session, _session_id}, 1_000

    assert [%{kind: "heartbeat", heartbeat_id: ^heartbeat_id} = run] =
             Enum.filter(Runs.list_recent(limit: 10), &(&1.heartbeat_id == heartbeat_id))

    refute Enum.any?(Runs.list_recent(limit: 10), &(&1.prompt == "disabled prompt"))
    assert {:ok, _cancelled} = Daemon.cancel(daemon, run.id)
  end

  test "manual trigger uses the loaded routine and no-overlap rejects re-entry" do
    {daemon, task_supervisor} = start_test_daemon(sessions: FakeSessions)
    heartbeat_id = Ecto.UUID.generate()
    scheduler = start_scheduler([heartbeat(heartbeat_id, "manual")], daemon, task_supervisor)

    assert {:ok, first} = LocalScheduler.trigger(scheduler, "manual")
    assert_receive {:waiting_session, _session_id}, 1_000
    assert {:error, :overlap} = LocalScheduler.trigger(scheduler, "manual")
    assert {:error, :not_found} = LocalScheduler.trigger(scheduler, "missing")
    assert {:ok, _cancelled} = Daemon.cancel(daemon, first.id)
  end

  test "restart reloads config and schedules only a future run instead of replaying a miss" do
    {daemon, task_supervisor} = start_test_daemon(sessions: FakeSessions)
    {:ok, configs} = Agent.start_link(fn -> [heartbeat(Ecto.UUID.generate(), "before")] end)

    scheduler =
      start_scheduler(fn -> Agent.get(configs, & &1) end, daemon, task_supervisor)

    assert [%{name: "before", next_run_at: before_next}] = LocalScheduler.status(scheduler)
    assert DateTime.compare(before_next, DateTime.utc_now()) == :gt

    Agent.update(configs, fn _ -> [heartbeat(Ecto.UUID.generate(), "after")] end)
    {:registered_name, scheduler_name} = Process.info(scheduler, :registered_name)
    Process.exit(scheduler, :kill)

    restarted = wait_for_restarted_scheduler(scheduler_name, scheduler)
    assert [%{name: "after", next_run_at: after_next}] = LocalScheduler.status(restarted)
    assert DateTime.compare(after_next, DateTime.utc_now()) == :gt
    refute_receive {:waiting_session, _session_id}, 100
    assert [] = Enum.filter(Runs.list_recent(limit: 10), &(&1.kind == "heartbeat"))
  end

  test "manual and due generic routines dispatch their configured kind" do
    {daemon, task_supervisor} = start_test_daemon(sessions: FakeSessions)

    configs = [
      routine(Ecto.UUID.generate(), "scheduled", "schedule"),
      routine(Ecto.UUID.generate(), "reflection", "dream")
    ]

    scheduler = start_scheduler(configs, daemon, task_supervisor)

    assert {:ok, schedule} = LocalScheduler.trigger(scheduler, "scheduled")
    assert schedule.kind == "schedule"
    assert_receive {:waiting_session, _session_id}, 1_000

    %{timers: %{"reflection" => %{token: dream_token}}} = :sys.get_state(scheduler)
    send(scheduler, {:fire, "reflection", dream_token})

    assert {:ok, _queued_dream} =
             wait_for(fn ->
               case Enum.find(Runs.list_recent(limit: 10), &(&1.kind == "dream")) do
                 nil -> :retry
                 run -> {:ok, run}
               end
             end)

    assert {:ok, _cancelled} = Daemon.cancel(daemon, schedule.id)
  end

  defp start_scheduler(configs_or_loader, daemon, task_supervisor) do
    name = String.to_atom("heartbeat_scheduler_test_#{System.unique_integer([:positive])}")

    loader =
      if is_function(configs_or_loader, 0),
        do: configs_or_loader,
        else: fn -> configs_or_loader end

    start_supervised!(
      {LocalScheduler,
       name: name,
       daemon: daemon,
       task_supervisor: task_supervisor,
       config_loader: loader,
       reload_interval_ms: :timer.hours(1)}
    )
  end

  defp wait_for_restarted_scheduler(name, old_pid) do
    {:ok, pid} =
      wait_for(fn ->
        case Process.whereis(name) do
          pid when is_pid(pid) and pid != old_pid -> {:ok, pid}
          _ -> :retry
        end
      end)

    pid
  end

  defp heartbeat(id, name, opts \\ []) do
    %{
      id: id,
      name: name,
      schedule: "* * * * *",
      enabled: Keyword.get(opts, :enabled, true),
      prompt: "#{name} prompt",
      agent_name: "main",
      tool_profile: "assistant_basic",
      no_overlap: true,
      max_runtime_ms: 1_000,
      keep_history: false,
      notify_user: false
    }
  end

  defp routine(id, name, kind) do
    %{
      id: id,
      name: name,
      kind: kind,
      schedule: "* * * * *",
      enabled: true,
      prompt: "#{name} prompt",
      agent_name: "main",
      tool_profile: "assistant_basic",
      no_overlap: true,
      max_runtime_ms: 1_000
    }
  end
end
