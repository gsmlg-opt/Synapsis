defmodule Synapsis.Agent.Heartbeat.AutomationRetirementFunctionalTest do
  use Synapsis.Agent.DaemonCase, async: false
  @moduletag :functional

  alias Synapsis.Agent.Heartbeat.{LocalScheduler, Worker}

  defmodule RecoveryRuns do
    alias Synapsis.Agent.Runs

    def list_by_status_result("queued" = status, opts) do
      result = Runs.list_by_status_result(status, opts)

      send(
        Application.fetch_env!(:synapsis_agent, :daemon_test_owner),
        {:retirement_recovery, self()}
      )

      receive do
        :release_retirement_recovery -> result
      end
    end

    def list_by_status_result(status, opts), do: Runs.list_by_status_result(status, opts)
    defdelegate create(attrs), to: Runs
    defdelegate fetch(id), to: Runs
    defdelegate get(id), to: Runs
    defdelegate fetch_by_idempotency_key(key), to: Runs
    defdelegate mark_running(run, attrs), to: Runs
    defdelegate mark_completed(run, summary), to: Runs
    defdelegate mark_completed(run, summary, attrs), to: Runs
    defdelegate mark_failed(run, reason), to: Runs
    defdelegate mark_failed(run, reason, attrs), to: Runs
    defdelegate mark_cancelled(run), to: Runs
    defdelegate mark_cancelled(run, attrs), to: Runs
    defdelegate mark_interrupted(run, reason), to: Runs
  end

  setup do
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :waiting)
    :ok
  end

  test "retirement captures a compatibility producer and preserves its source sibling and future work" do
    {daemon, supervisor} = start_test_daemon(sessions: FakeSessions)
    id = Ecto.UUID.generate()
    config = config(id, "routine")
    sibling = config(id, "heartbeat")
    {scheduler, inventory} = scheduler([config, sibling], daemon, supervisor)
    sibling_key = {"heartbeat", id}
    sibling_timer = :sys.get_state(scheduler).timers[sibling_key]

    caller = Task.async(fn -> LocalScheduler.trigger(scheduler, {"routine", id}) end)
    assert_receive {:retirement_producer, producer, daemon_pid}, 1_000
    assert daemon_pid == Process.whereis(daemon)

    commit_removal(inventory, {"routine", id})
    assert {:ok, observation} = LocalScheduler.retire(scheduler, {"routine", id})
    assert observation.status == :cancellation_requested
    assert observation.producer_count == 1
    assert observation.cleanup_pending
    assert :sys.get_state(scheduler).timers[sibling_key] == sibling_timer
    assert [%{source: "heartbeat", id: ^id}] = LocalScheduler.status(scheduler)

    send(producer, :submit_retirement_producer)
    assert {:ok, %Synapsis.AgentRun{} = retired_run} = Task.await(caller)
    eventually(fn -> Runs.get(retired_run.id).status == "cancelled" end)

    committed = Map.put(config, "enabled", false)
    Agent.update(inventory, &[committed | &1])
    assert {:ok, _} = LocalScheduler.retire(scheduler, {"routine", id}, config: committed)
    future = Task.async(fn -> LocalScheduler.run(scheduler, {"routine", id}, :force) end)
    assert_receive {:retirement_producer, fresh_producer, ^daemon_pid}, 1_000
    send(fresh_producer, :submit_retirement_producer)
    assert {:ok, %{enqueued: true, run: fresh_run}} = Task.await(future)
    assert_receive {:waiting_session, _session_id}, 1_000
    assert {:ok, _} = Daemon.cancel(daemon, fresh_run.id)
    eventually(fn -> Runs.get(fresh_run.id).status == "cancelled" end)
  end

  for mode <- [:force, :due, :timer] do
    test "retirement captures the #{mode} producer before its Daemon admission" do
      assert_producer_retirement(unquote(mode))
    end
  end

  for origin <- [:active, :recovery] do
    test "a delayed terminal from a Daemon-only #{origin} Run preserves the reenabled timer" do
      assert_daemon_only_retirement(unquote(origin))
    end
  end

  defp assert_daemon_only_retirement(origin) do
    config = typed_config()
    id = config["id"]
    key = {"routine", id}
    old_occurrence = DateTime.add(DateTime.utc_now(), -3_600, :second) |> DateTime.to_iso8601()

    context = %{
      "generation" => config["schedule_generation"],
      "occurrence" => old_occurrence,
      "preserved_next_run_at" => old_occurrence,
      "advance" => true
    }

    options = %{
      heartbeat_id: id,
      routine_id: id,
      prompt: "daemon-only retirement",
      assistant_name: "main",
      no_overlap: false,
      metadata: %{
        "automation_ref" => %{"source" => "routine", "id" => id},
        "routine_schedule" => context
      }
    }

    recovered =
      if origin == :recovery do
        assert {:ok, attrs} = Synapsis.Agent.Daemon.Execution.heartbeat_attrs(options)
        assert {:ok, run} = Runs.create(attrs)
        run
      end

    daemon_opts =
      if origin == :recovery,
        do: [sessions: FakeSessions, runs: RecoveryRuns, recover?: true],
        else: [sessions: FakeSessions]

    {daemon, supervisor} = start_test_daemon(daemon_opts)

    recovery =
      if origin == :recovery do
        assert_receive {:retirement_recovery, task}, 1_000
        task
      end

    {scheduler, inventory} = scheduler([config], daemon, supervisor)
    :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, Daemon.topic())

    :sys.replace_state(scheduler, fn state ->
      :ok = Phoenix.PubSub.unsubscribe(Synapsis.PubSub, Daemon.topic())
      state
    end)

    run =
      if recovered do
        recovered
      else
        assert {:ok, run} = Daemon.trigger(daemon, :heartbeat, options)
        assert_receive {:waiting_session, _session_id}, 1_000
        run
      end

    assert :sys.get_state(scheduler).tracked_runs == %{}
    disabled = Map.put(config, "enabled", false)
    Agent.update(inventory, fn _ -> [disabled] end)
    assert {:ok, _} = LocalScheduler.retire(scheduler, key, config: disabled)

    fresh_slot = DateTime.add(DateTime.utc_now(), 7_200, :second) |> DateTime.to_iso8601()
    reenabled = Map.put(config, "next_run_at", fresh_slot)
    Agent.update(inventory, fn _ -> [reenabled] end)
    assert :ok = LocalScheduler.reload(scheduler)
    fresh_timer = :sys.get_state(scheduler).timers[key]
    assert fresh_timer.generation == config["schedule_generation"]

    if recovery, do: send(recovery, :release_retirement_recovery)
    run_id = run.id

    assert_receive {:agent_daemon_event,
                    %{event: "agent.run.cancelled", run_id: ^run_id} = terminal},
                   2_000

    eventually(fn -> Runs.get(run_id).status == "cancelled" end)
    send(scheduler, {:agent_daemon_event, terminal})
    assert [%{id: ^id, next_run_at: next}] = LocalScheduler.status(scheduler)
    assert DateTime.to_iso8601(next) == fresh_slot
    assert :sys.get_state(scheduler).timers[key] == fresh_timer
    assert [saved] = Agent.get(inventory, & &1)
    assert saved["enabled"]
    assert saved["schedule_generation"] == config["schedule_generation"]
    assert saved["next_run_at"] == fresh_slot
  end

  defp typed_config do
    now = System.system_time(:millisecond)
    schedule = %{"kind" => "every", "everyMs" => 3_600_000, "anchorMs" => now}
    {:ok, fingerprint} = Synapsis.RoutineSchedule.fingerprint(schedule, "Etc/UTC")

    config(Ecto.UUID.generate(), "routine")
    |> Map.merge(%{
      "schedule" => schedule,
      "schedule_generation" => Ecto.UUID.generate(),
      "schedule_fingerprint" => fingerprint,
      "createdAtMs" => now,
      "next_run_at" => DateTime.from_unix!(now + 3_600_000, :millisecond) |> DateTime.to_iso8601()
    })
  end

  defp assert_producer_retirement(mode) do
    {daemon, supervisor} = start_test_daemon(sessions: FakeSessions)
    config = config(Ecto.UUID.generate(), "routine")
    {scheduler, inventory} = scheduler([config], daemon, supervisor)
    key = {"routine", config["id"]}

    caller =
      if mode == :timer do
        make_due(scheduler, key)
        timer = :sys.get_state(scheduler).timers[key]
        send(scheduler, {:fire, key, timer.token})
        nil
      else
        if mode == :due, do: make_due(scheduler, key)
        Task.async(fn -> LocalScheduler.run(scheduler, key, mode) end)
      end

    assert_receive {:retirement_producer, producer, daemon_pid}, 1_000
    assert daemon_pid == Process.whereis(daemon)
    commit_removal(inventory, key)
    assert {:ok, observation} = LocalScheduler.retire(scheduler, key)
    assert observation.producer_count == 1
    assert observation.target == key
    assert [] = LocalScheduler.status(scheduler)
    send(producer, :submit_retirement_producer)

    run =
      if caller do
        assert {:ok, %{enqueued: true, run: run}} = Task.await(caller)
        run
      else
        eventually(fn ->
          Enum.any?(Runs.list_recent(limit: 10), &(&1.routine_id == config["id"]))
        end)

        Enum.find(Runs.list_recent(limit: 10), &(&1.routine_id == config["id"]))
      end

    eventually(fn -> Runs.get(run.id).status == "cancelled" end)
  end

  defp scheduler(configs, daemon, supervisor) do
    owner = self()
    name = String.to_atom("retirement_scheduler_#{System.unique_integer([:positive])}")
    inventory = start_supervised!({Agent, fn -> configs end}, id: make_ref())

    scheduler =
      start_supervised!(
        {LocalScheduler,
         name: name,
         daemon: daemon,
         task_supervisor: supervisor,
         config_loader: fn -> Agent.get(inventory, & &1) end,
         config_writer: fn type, attrs ->
           Agent.update(inventory, fn entries ->
             Enum.map(entries, fn entry ->
               if entry["__config_type"] == Atom.to_string(type) and entry["id"] == attrs["id"],
                 do:
                   Map.merge(
                     entry,
                     Map.drop(attrs, ["__schedule_generation", "__schedule_fingerprint"])
                   ),
                 else: entry
             end)
           end)

           {:ok, attrs}
         end,
         trigger_fun: fn config, daemon_pid ->
           send(owner, {:retirement_producer, self(), daemon_pid})

           receive do
             :submit_retirement_producer -> Worker.execute(config, daemon_pid)
           end
         end,
         reload_interval_ms: 60_000}
      )

    :ok = LocalScheduler.reload(scheduler)
    {scheduler, inventory}
  end

  defp commit_removal(inventory, {source, id}) do
    Agent.update(inventory, fn configs ->
      Enum.reject(configs, &(&1["__config_type"] == source and &1["id"] == id))
    end)
  end

  defp config(id, source) do
    %{
      "id" => id,
      "name" => "retirement-#{source}",
      "kind" => "heartbeat",
      "enabled" => true,
      "schedule" => "0 0 * * *",
      "timezone" => "Etc/UTC",
      "prompt" => "retirement lifecycle",
      "agent_name" => "main",
      "__config_type" => source
    }
  end

  defp make_due(scheduler, key) do
    :sys.replace_state(scheduler, fn state ->
      put_in(state.timers[key].next_run_at, DateTime.add(DateTime.utc_now(), -1, :second))
    end)
  end

  defp eventually(fun) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    await_condition(fun, deadline)
  end

  defp await_condition(fun, deadline) do
    if fun.() do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(10)
      await_condition(fun, deadline)
    end
  end
end
