defmodule Synapsis.Agent.Heartbeat.LocalSchedulerTest do
  use Synapsis.Agent.DaemonCase, async: false

  defmodule BlockingFetchRuns do
    def fetch(_run_id) do
      send(Application.fetch_env!(:synapsis_agent, :daemon_test_owner), {:runs_fetch, self()})

      receive do
        :release_fetch -> :not_found
      end
    end
  end

  alias Synapsis.Agent.Heartbeat.LocalScheduler
  alias Synapsis.Agent.RunEvents
  alias Synapsis.Config.Store, as: ConfigStore

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

    %{timers: %{^heartbeat_id => %{token: token}}} = :sys.get_state(scheduler)
    send(scheduler, {:fire, heartbeat_id, token})

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

  test "stable IDs survive rename and synchronous reload uses the current config" do
    {daemon, task_supervisor} = start_test_daemon(sessions: FakeSessions)
    owner = self()
    routine_id = Ecto.UUID.generate()
    before = routine(routine_id, "before-rename", "schedule")
    {:ok, configs} = Agent.start_link(fn -> [before] end)

    scheduler =
      start_scheduler(fn -> Agent.get(configs, & &1) end, daemon, task_supervisor,
        trigger_fun: fn config, _daemon ->
          send(owner, {:triggered_config, config})
          {:error, :observed}
        end,
        config_writer: fn _type, attrs -> {:ok, attrs} end
      )

    assert [%{id: ^routine_id, name: "before-rename"}] = LocalScheduler.status(scheduler)
    %{timers: %{^routine_id => %{ref: timer_ref}}} = :sys.get_state(scheduler)

    Agent.update(configs, fn [config] -> [%{config | name: "after-rename"}] end)
    assert :ok = LocalScheduler.reload(scheduler)

    assert [%{id: ^routine_id, name: "after-rename"}] = LocalScheduler.status(scheduler)
    assert %{timers: %{^routine_id => %{ref: ^timer_ref}}} = :sys.get_state(scheduler)

    assert {:error, :observed} = LocalScheduler.trigger(scheduler, routine_id)
    assert_receive {:triggered_config, %{id: ^routine_id, name: "after-rename"}}
    assert {:error, :not_found} = LocalScheduler.trigger(scheduler, "before-rename")
  end

  test "legacy names resolve exactly one enabled config and reject ambiguity or disabled IDs" do
    {daemon, task_supervisor} = start_test_daemon(sessions: FakeSessions)
    first_id = Ecto.UUID.generate()
    second_id = Ecto.UUID.generate()
    disabled_id = Ecto.UUID.generate()

    scheduler =
      start_scheduler(
        [
          routine(first_id, "duplicate", "schedule"),
          routine(second_id, "duplicate", "dream"),
          %{routine(disabled_id, "disabled", "schedule") | enabled: false}
        ],
        daemon,
        task_supervisor
      )

    assert {:error, :ambiguous} = LocalScheduler.trigger(scheduler, "duplicate")
    assert {:error, :disabled} = LocalScheduler.trigger(scheduler, disabled_id)
    assert {:error, :not_found} = LocalScheduler.trigger(scheduler, Ecto.UUID.generate())

    assert [first, second] =
             LocalScheduler.status(scheduler) |> Enum.filter(&(&1.name == "duplicate"))

    assert MapSet.new([first.id, second.id]) == MapSet.new([first_id, second_id])
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

  test "persists the next run when a routine schedule is loaded" do
    {daemon, task_supervisor} = start_test_daemon(sessions: FakeSessions)
    owner = self()
    config = routine(Ecto.UUID.generate(), "persisted-next-run", "schedule")

    _scheduler =
      start_scheduler([config], daemon, task_supervisor,
        config_writer: fn type, attrs ->
          send(owner, {:routine_config_written, type, attrs})
          {:ok, attrs}
        end
      )

    assert_receive {:routine_config_written, :routine, attrs}, 1_000
    assert attrs["id"] == config.id
    assert is_binary(attrs["next_run_at"])
    refute Map.has_key?(attrs, "last_status")
  end

  test "persists a routine terminal outcome instead of its queued submission state" do
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :immediate_done)
    {daemon, task_supervisor} = start_test_daemon(sessions: FakeSessions)
    owner = self()
    config = routine(Ecto.UUID.generate(), "terminal-routine", "schedule")

    scheduler =
      start_scheduler([config], daemon, task_supervisor,
        config_writer: fn type, attrs ->
          send(owner, {:routine_config_written, type, attrs})
          {:ok, attrs}
        end
      )

    assert_receive {:routine_config_written, :routine, %{"next_run_at" => next_run_at}}, 1_000
    assert is_binary(next_run_at)

    assert {:ok, run} = LocalScheduler.trigger(scheduler, "terminal-routine")
    assert {:ok, _completed} = wait_for_run(run.id, "completed")

    refute_receive {:routine_config_written, :routine, %{"last_status" => "queued"}}, 100

    assert_receive {:routine_config_written, :routine,
                    %{
                      "last_status" => "completed",
                      "last_run_at" => last_run_at,
                      "next_run_at" => terminal_next_run_at
                    }},
                   1_000

    assert is_binary(last_run_at)
    assert terminal_next_run_at == next_run_at
  end

  test "persists a terminal event received before trigger correlation exactly once" do
    {daemon, task_supervisor} = start_test_daemon(sessions: FakeSessions)
    owner = self()
    config = routine(Ecto.UUID.generate(), "early-terminal", "schedule")

    scheduler =
      start_scheduler([config], daemon, task_supervisor,
        config_writer: fn type, attrs ->
          send(owner, {:routine_config_written, type, attrs})
          {:ok, attrs}
        end
      )

    assert_receive {:routine_config_written, :routine, %{"next_run_at" => next_run_at}}, 1_000
    run = completed_routine_run(config)
    :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, Daemon.topic())

    assert :ok = RunEvents.publish_lifecycle(:completed, run)

    assert_receive {:agent_daemon_event,
                    %{
                      run_id: run_id,
                      payload: %{
                        routine_id: routine_id,
                        started_at: started_at,
                        inserted_at: inserted_at
                      }
                    }},
                   1_000

    assert run_id == run.id
    assert routine_id == config.id
    assert started_at == DateTime.to_iso8601(run.started_at)
    assert inserted_at == DateTime.to_iso8601(run.inserted_at)

    GenServer.cast(
      scheduler,
      {:track_trigger, config.id, config, {:ok, run}, run.started_at, next_run_at}
    )

    assert_receive {:routine_config_written, :routine,
                    %{"last_status" => "completed", "last_run_at" => last_run_at}},
                   1_000

    assert is_binary(last_run_at)

    _state = :sys.get_state(scheduler)
    assert :ok = RunEvents.publish_lifecycle(:completed, run)

    refute_receive {:routine_config_written, :routine, %{"last_status" => "completed"}}, 100
  end

  test "ignores an unrelated terminal event without reading the run store" do
    {daemon, task_supervisor} = start_test_daemon(sessions: FakeSessions)
    config = routine(Ecto.UUID.generate(), "unrelated-terminal", "schedule")

    scheduler =
      start_scheduler([config], daemon, task_supervisor,
        runs: BlockingFetchRuns,
        config_writer: fn _type, attrs -> {:ok, attrs} end
      )

    manual_run = %Synapsis.AgentRun{
      id: Ecto.UUID.generate(),
      kind: "manual",
      status: "completed",
      prompt: "manual work",
      tool_profile: "assistant_basic",
      started_at: DateTime.utc_now(),
      inserted_at: DateTime.utc_now()
    }

    on_exit(fn ->
      if Process.alive?(scheduler), do: send(scheduler, :release_fetch)
    end)

    assert :ok = RunEvents.publish_lifecycle(:completed, manual_run)

    assert [%{name: "unrelated-terminal"}] =
             GenServer.call(scheduler, :status, 100)

    refute_receive {:runs_fetch, _scheduler}, 100
  end

  test "scheduler restart reconciles a terminal run from durable identity exactly once" do
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :controlled_done)
    {daemon, task_supervisor} = start_test_daemon(sessions: FakeSessions)
    owner = self()
    config = routine(Ecto.UUID.generate(), "restart-terminal", "schedule")

    scheduler =
      start_scheduler([config], daemon, task_supervisor,
        config_writer: fn type, attrs ->
          send(owner, {:routine_config_written, type, attrs})
          {:ok, attrs}
        end
      )

    assert_receive {:routine_config_written, :routine, %{"next_run_at" => _next_run_at}}, 1_000
    assert {:ok, run} = LocalScheduler.trigger(scheduler, config.name)
    assert_receive {:controlled_session, runner, _session_id}, 1_000

    assert {:ok, true} =
             wait_for(fn ->
               if Map.has_key?(:sys.get_state(scheduler).tracked_runs, run.id),
                 do: {:ok, true},
                 else: :retry
             end)

    {:registered_name, scheduler_name} = Process.info(scheduler, :registered_name)
    Process.exit(scheduler, :kill)
    restarted = wait_for_restarted_scheduler(scheduler_name, scheduler)

    send(runner, :complete_session)
    assert {:ok, _completed} = wait_for_run(run.id, "completed")

    assert_receive {:routine_config_written, :routine,
                    %{"last_status" => "completed", "last_run_at" => last_run_at}},
                   1_000

    assert is_binary(last_run_at)
    refute_receive {:routine_config_written, :routine, %{"last_status" => "completed"}}, 100

    assert [%{last_status: "completed"}] = LocalScheduler.status(restarted)
  end

  test "serializes routine persistence so a delayed next-run write cannot erase terminal state" do
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :immediate_done)
    {daemon, task_supervisor} = start_test_daemon(sessions: FakeSessions)
    owner = self()
    config = routine(Ecto.UUID.generate(), "ordered-routine", "schedule")
    {:ok, writes} = Agent.start_link(fn -> %{count: 0, persisted: nil} end)

    scheduler =
      start_scheduler([config], daemon, task_supervisor,
        config_writer: fn type, attrs ->
          index =
            Agent.get_and_update(writes, fn state ->
              {state.count + 1, %{state | count: state.count + 1}}
            end)

          send(owner, {:routine_write_started, index, type, attrs, self()})

          if index == 1 do
            receive do
              :release_next_run_write -> :ok
            end
          end

          Agent.update(writes, &%{&1 | persisted: attrs})
          send(owner, {:routine_write_finished, index, attrs})
          {:ok, attrs}
        end
      )

    assert_receive {:routine_write_started, 1, :routine, next_attrs, delayed_writer}, 1_000
    refute Map.has_key?(next_attrs, "last_status")

    assert {:ok, run} = LocalScheduler.trigger(scheduler, "ordered-routine")
    assert {:ok, _completed} = wait_for_run(run.id, "completed")

    refute_receive {:routine_write_started, 2, :routine, _attrs, _writer}, 100

    send(delayed_writer, :release_next_run_write)
    assert_receive {:routine_write_finished, 1, ^next_attrs}, 1_000

    assert_receive {:routine_write_started, 2, :routine,
                    %{"last_status" => "completed"} = terminal_attrs, _writer},
                   1_000

    assert_receive {:routine_write_finished, 2, ^terminal_attrs}, 1_000
    assert Agent.get(writes, & &1.persisted) == terminal_attrs
  end

  test "retries a transient terminal persistence failure with the complete snapshot" do
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :immediate_done)
    {daemon, task_supervisor} = start_test_daemon(sessions: FakeSessions)
    owner = self()
    config = routine(Ecto.UUID.generate(), "retry-terminal-routine", "schedule")
    {:ok, terminal_attempts} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> ConfigStore.delete(:routine, config.id) end)

    scheduler =
      start_scheduler([config], daemon, task_supervisor,
        persistence_retry_backoff_ms: 20,
        persistence_retry_limit: 2,
        config_writer: fn type, attrs ->
          if Map.has_key?(attrs, "last_status") do
            attempt = Agent.get_and_update(terminal_attempts, &{&1 + 1, &1 + 1})
            send(owner, {:terminal_persist_attempt, attempt, attrs})

            if attempt == 1,
              do: {:error, :store_unavailable},
              else: ConfigStore.put(type, attrs)
          else
            ConfigStore.put(type, attrs)
          end
        end
      )

    assert {:ok, run} = LocalScheduler.trigger(scheduler, "retry-terminal-routine")
    assert {:ok, _completed} = wait_for_run(run.id, "completed")
    assert_receive {:terminal_persist_attempt, 1, terminal_attrs}, 1_000
    assert_receive {:terminal_persist_attempt, 2, retried_attrs}, 1_000
    assert retried_attrs == terminal_attrs

    assert {:ok, %{"last_run_at" => last_run_at, "last_status" => "completed"}} =
             wait_for(fn ->
               case ConfigStore.get(:routine, config.id) do
                 {:ok, %{"last_status" => "completed"} = attrs} -> {:ok, attrs}
                 _pending -> :retry
               end
             end)

    assert is_binary(last_run_at)

    assert [%{last_run_at: ^last_run_at, last_status: "completed", last_error: nil}] =
             LocalScheduler.status(scheduler)
  end

  for failure <- [:timeout, :down] do
    test "retries terminal persistence after #{failure}" do
      failure = unquote(failure)
      Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :immediate_done)
      {daemon, task_supervisor} = start_test_daemon(sessions: FakeSessions)
      owner = self()
      name = "retry-terminal-#{failure}"
      config = routine(Ecto.UUID.generate(), name, "schedule")
      {:ok, persisted} = Agent.start_link(fn -> nil end)
      {:ok, terminal_attempts} = Agent.start_link(fn -> 0 end)

      scheduler =
        start_scheduler([config], daemon, task_supervisor,
          trigger_timeout_ms: 30,
          persistence_retry_backoff_ms: 20,
          persistence_retry_limit: 2,
          config_writer: retrying_config_writer(owner, persisted, terminal_attempts, failure)
        )

      assert {:ok, run} = LocalScheduler.trigger(scheduler, name)
      assert {:ok, _completed} = wait_for_run(run.id, "completed")
      assert_receive {:terminal_persist_attempt, 1, terminal_attrs}, 1_000
      assert_receive {:terminal_persist_attempt, 2, retried_attrs}, 1_000
      assert retried_attrs == terminal_attrs
      assert %{"last_status" => "completed"} = Agent.get(persisted, & &1)
    end
  end

  test "stops retrying terminal persistence after the configured bound" do
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :immediate_done)
    {daemon, task_supervisor} = start_test_daemon(sessions: FakeSessions)
    owner = self()
    config = routine(Ecto.UUID.generate(), "bounded-terminal-retries", "schedule")

    scheduler =
      start_scheduler([config], daemon, task_supervisor,
        persistence_retry_backoff_ms: 10,
        persistence_retry_limit: 2,
        config_writer: fn _type, attrs ->
          if Map.has_key?(attrs, "last_status") do
            send(owner, {:terminal_persist_failed, attrs})
            {:error, :store_unavailable}
          else
            {:ok, attrs}
          end
        end
      )

    assert {:ok, run} = LocalScheduler.trigger(scheduler, "bounded-terminal-retries")
    assert {:ok, _completed} = wait_for_run(run.id, "completed")
    assert_receive {:terminal_persist_failed, _attrs}, 1_000
    assert_receive {:terminal_persist_failed, _attrs}, 1_000
    assert_receive {:terminal_persist_failed, _attrs}, 1_000
    refute_receive {:terminal_persist_failed, _attrs}, 100
  end

  test "persists and exposes a heartbeat terminal outcome without changing its config shape" do
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :immediate_done)
    {daemon, task_supervisor} = start_test_daemon(sessions: FakeSessions)
    owner = self()
    heartbeat_id = Ecto.UUID.generate()
    config = heartbeat(heartbeat_id, "terminal-heartbeat")

    scheduler =
      start_scheduler([config], daemon, task_supervisor,
        config_writer: fn type, attrs ->
          send(owner, {:routine_config_written, type, attrs})
          {:ok, attrs}
        end
      )

    assert_receive {:routine_config_written, :heartbeat, %{"next_run_at" => next_run_at}}, 1_000
    assert is_binary(next_run_at)
    assert {:ok, run} = LocalScheduler.trigger(scheduler, "terminal-heartbeat")
    assert {:ok, _completed} = wait_for_run(run.id, "completed")

    assert_receive {:routine_config_written, :heartbeat,
                    %{"last_status" => "completed", "last_run_at" => last_run_at}},
                   1_000

    assert is_binary(last_run_at)

    assert [%{last_status: "completed", last_run_at: ^last_run_at}] =
             LocalScheduler.status(scheduler)
  end

  test "manual and due generic routines dispatch their configured kind" do
    {daemon, task_supervisor} = start_test_daemon(sessions: FakeSessions)
    owner = self()

    reflection_id = Ecto.UUID.generate()

    configs = [
      routine(Ecto.UUID.generate(), "scheduled", "schedule"),
      routine(reflection_id, "reflection", "dream")
    ]

    scheduler =
      start_scheduler(configs, daemon, task_supervisor,
        config_writer: fn type, attrs ->
          send(owner, {:routine_config_written, type, attrs})
          {:ok, attrs}
        end
      )

    assert {:ok, schedule} = LocalScheduler.trigger(scheduler, "scheduled")
    assert schedule.kind == "schedule"
    assert_receive {:waiting_session, _session_id}, 1_000

    %{timers: %{^reflection_id => %{token: dream_token}}} = :sys.get_state(scheduler)
    send(scheduler, {:fire, reflection_id, dream_token})

    assert {:ok, _queued_dream} =
             wait_for(fn ->
               case Enum.find(Runs.list_recent(limit: 10), &(&1.kind == "dream")) do
                 nil -> :retry
                 run -> {:ok, run}
               end
             end)

    assert {:ok, _cancelled} = Daemon.cancel(daemon, schedule.id)
  end

  test "a due routine trigger is monitored, bounded, and exposes timeout errors" do
    {daemon, task_supervisor} = start_test_daemon(sessions: FakeSessions)
    owner = self()
    config = routine(Ecto.UUID.generate(), "hung", "schedule")

    scheduler =
      start_scheduler([config], daemon, task_supervisor,
        trigger_timeout_ms: 50,
        trigger_fun: fn _config, _daemon ->
          send(owner, {:routine_trigger_started, self()})
          receive do: (:never -> :ok)
        end,
        config_writer: fn _type, attrs -> {:ok, attrs} end
      )

    config_id = config.id
    %{timers: %{^config_id => %{token: token}}} = :sys.get_state(scheduler)
    send(scheduler, {:fire, config_id, token})

    assert_receive {:routine_trigger_started, trigger_pid}, 1_000

    assert {:ok, status} =
             wait_for(fn ->
               case LocalScheduler.status(scheduler) do
                 [%{last_status: "error"} = status] -> {:ok, status}
                 _other -> :retry
               end
             end)

    assert status.last_error =~ "trigger_timeout"
    refute Process.alive?(trigger_pid)
    assert Process.alive?(scheduler)
  end

  defp start_scheduler(configs_or_loader, daemon, task_supervisor, opts \\ []) do
    name = String.to_atom("heartbeat_scheduler_test_#{System.unique_integer([:positive])}")

    loader =
      if is_function(configs_or_loader, 0),
        do: configs_or_loader,
        else: fn -> configs_or_loader end

    scheduler_opts =
      Keyword.merge(
        [
          name: name,
          daemon: daemon,
          task_supervisor: task_supervisor,
          config_loader: loader,
          config_writer: fn _type, attrs -> {:ok, attrs} end,
          reload_interval_ms: :timer.hours(1)
        ],
        opts
      )

    start_supervised!({LocalScheduler, scheduler_opts})
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

  defp completed_routine_run(config) do
    assert {:ok, queued} =
             Runs.create(%{
               kind: config.kind,
               status: "queued",
               source: "system",
               assistant_name: config.agent_name,
               routine_id: config.id,
               prompt: config.prompt,
               tool_profile: config.tool_profile,
               metadata: %{"routine_name" => config.name}
             })

    assert {:ok, running} = Runs.mark_running(queued)
    assert {:ok, completed} = Runs.mark_completed(running, "done")
    completed
  end

  defp retrying_config_writer(owner, persisted, terminal_attempts, failure) do
    fn _type, attrs ->
      if Map.has_key?(attrs, "last_status") do
        attempt = Agent.get_and_update(terminal_attempts, &{&1 + 1, &1 + 1})
        send(owner, {:terminal_persist_attempt, attempt, attrs})

        case {attempt, failure} do
          {1, :timeout} ->
            receive do
              :never -> :ok
            end

          {1, :down} ->
            Process.exit(self(), :kill)

          _retry ->
            Agent.update(persisted, fn _current -> attrs end)
            {:ok, attrs}
        end
      else
        Agent.update(persisted, fn _current -> attrs end)
        {:ok, attrs}
      end
    end
  end
end
