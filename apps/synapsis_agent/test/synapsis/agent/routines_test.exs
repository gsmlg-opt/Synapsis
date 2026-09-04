defmodule Synapsis.Agent.RoutinesTest do
  use Synapsis.Agent.DataCase, async: false

  alias Synapsis.Agent.Heartbeat.LocalScheduler
  alias Synapsis.Agent.Routines
  alias Synapsis.AgentRun
  alias Synapsis.Config.Store

  test "create generates a stable UUID and makes the routine listable" do
    scheduler = isolated_scheduler()

    assert {:ok,
            %{
              "id" => id,
              "name" => "nightly-check",
              "kind" => "schedule",
              "enabled" => true
            }} =
             Routines.create(
               %{
                 "name" => "nightly-check",
                 "kind" => "schedule",
                 "enabled" => true,
                 "schedule" => "0 2 * * *",
                 "prompt" => "inspect nightly state"
               },
               scheduler: scheduler
             )

    on_exit(fn -> Store.delete(:routine, id) end)
    assert {:ok, _uuid} = Ecto.UUID.cast(id)

    assert %{"id" => ^id, "name" => "nightly-check"} =
             Enum.find(Routines.list("schedule"), &(&1["id"] == id))
  end

  test "create and update publish durable routine changes" do
    scheduler = isolated_scheduler()
    :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "agent:daemon")

    assert {:ok, %{"id" => id}} =
             Routines.create(routine_attrs("evented"), scheduler: scheduler)

    on_exit(fn -> Store.delete(:routine, id) end)

    assert_receive {:agent_daemon_event,
                    %{
                      event: "agent.routine.updated",
                      routine_id: ^id,
                      kind: "schedule",
                      at: %DateTime{}
                    }}

    assert {:ok, %{"name" => "renamed"}} =
             Routines.update(id, %{"name" => "renamed"}, scheduler: scheduler)

    assert_receive {:agent_daemon_event,
                    %{
                      event: "agent.routine.updated",
                      routine_id: ^id,
                      kind: "schedule",
                      at: %DateTime{}
                    }}
  end

  test "scheduler reload exits leave created and updated routines durably disabled" do
    :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "agent:daemon")
    dead_scheduler = spawn(fn -> :ok end)
    ref = Process.monitor(dead_scheduler)
    assert_receive {:DOWN, ^ref, :process, ^dead_scheduler, _reason}

    name = "reload-down-#{System.unique_integer([:positive])}"

    assert {:error, {:scheduler_reload_failed, _reason}} =
             Routines.create(routine_attrs(name), scheduler: dead_scheduler)

    assert [%{"id" => id, "enabled" => false}] =
             Enum.filter(Routines.list("schedule"), &(&1["name"] == name))

    on_exit(fn -> Store.delete(:routine, id) end)

    assert_receive {:agent_daemon_event,
                    %{
                      event: "agent.routine.updated",
                      routine_id: ^id,
                      kind: "schedule"
                    }}

    assert {:error, {:scheduler_reload_failed, _reason}} =
             Routines.update(id, %{"enabled" => true, "prompt" => "updated prompt"},
               scheduler: dead_scheduler
             )

    assert {:ok, %{"enabled" => false, "prompt" => "updated prompt"}} = Store.get(:routine, id)

    assert_receive {:agent_daemon_event,
                    %{
                      event: "agent.routine.updated",
                      routine_id: ^id,
                      kind: "schedule"
                    }}
  end

  test "reload failure removes an existing routine from the live scheduler" do
    owner = self()
    id = Ecto.UUID.generate()
    attrs = Map.put(routine_attrs("stale-runtime"), "id", id)
    assert {:ok, routine} = Store.put(:routine, attrs)
    on_exit(fn -> Store.delete(:routine, id) end)
    {:ok, loader} = Agent.start_link(fn -> {:ok, [routine]} end)
    task_supervisor = start_supervised!({Task.Supervisor, []})

    scheduler =
      start_supervised!(
        {LocalScheduler,
         name: String.to_atom("routines_fail_closed_#{System.unique_integer([:positive])}"),
         daemon: :test_daemon,
         task_supervisor: task_supervisor,
         config_loader: fn ->
           case Agent.get(loader, & &1) do
             {:ok, configs} -> configs
             :fail -> raise "injected reload failure"
           end
         end,
         config_writer: fn _type, written -> {:ok, written} end,
         trigger_fun: fn config, _daemon ->
           send(owner, {:unexpected_trigger, config})
           {:error, :unexpected_trigger}
         end,
         reload_interval_ms: :timer.hours(1)}
      )

    assert [%{id: ^id}] = LocalScheduler.status(scheduler)
    Agent.update(loader, fn _current -> :fail end)

    assert {:error, {:scheduler_reload_failed, :reload_failed}} =
             Routines.update(id, %{"name" => "must-not-run"}, scheduler: scheduler)

    assert {:ok, %{"enabled" => false, "name" => "must-not-run"}} = Store.get(:routine, id)
    assert [] = LocalScheduler.status(scheduler)
    assert {:error, :not_found} = LocalScheduler.trigger(scheduler, id)
    refute_receive {:unexpected_trigger, _config}, 50
  end

  test "reload failure retries a transient fail-closed write against the real store" do
    id = Ecto.UUID.generate()

    assert {:ok, _routine} =
             Store.put(:routine, Map.put(routine_attrs("retry-disable"), "id", id))

    on_exit(fn -> Store.delete(:routine, id) end)
    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    task_supervisor = start_supervised!({Task.Supervisor, []})

    scheduler =
      start_supervised!(
        {LocalScheduler,
         name: String.to_atom("routines_retry_disable_#{System.unique_integer([:positive])}"),
         task_supervisor: task_supervisor,
         config_loader: fn -> raise "injected reload failure" end,
         reload_interval_ms: :timer.hours(1)}
      )

    fail_closed_writer = fn type, routine_id, patch ->
      case Agent.get_and_update(attempts, &{&1 + 1, &1 + 1}) do
        1 -> {:error, :transient_store_failure}
        2 -> Store.merge_existing(type, routine_id, patch)
      end
    end

    assert {:error, {:scheduler_reload_failed, :reload_failed}} =
             Routines.update(id, %{"enabled" => true},
               scheduler: scheduler,
               fail_closed_writer: fail_closed_writer
             )

    assert Agent.get(attempts, & &1) == 2
    assert {:ok, %{"enabled" => false}} = Store.get(:routine, id)
  end

  test "update merge-patches a routine without changing its stable ID" do
    scheduler = isolated_scheduler()
    assert {:ok, %{"id" => id}} = Routines.create(routine_attrs("before"), scheduler: scheduler)
    on_exit(fn -> Store.delete(:routine, id) end)

    assert {:ok,
            %{
              "id" => ^id,
              "name" => "after",
              "prompt" => "before prompt",
              "schedule" => "0 2 * * *"
            }} =
             Routines.update(id, %{"id" => Ecto.UUID.generate(), "name" => "after"},
               scheduler: scheduler
             )

    assert {:error, {:invalid_routine, :schedule}} =
             Routines.update(id, %{"schedule" => "not a cron"}, scheduler: scheduler)

    assert {:ok, %{"id" => ^id, "name" => "after", "schedule" => "0 2 * * *"}} =
             Routines.get(id)

    assert {:error, :not_found} =
             Routines.update(Ecto.UUID.generate(), %{"name" => "none"}, scheduler: scheduler)
  end

  test "update atomically preserves terminal fields written after its read" do
    scheduler = isolated_scheduler()

    assert {:ok, %{"id" => id}} =
             Routines.create(routine_attrs("before-race"), scheduler: scheduler)

    on_exit(fn -> Store.delete(:routine, id) end)
    owner = self()

    update =
      Task.async(fn ->
        Routines.update(id, %{"name" => "after-race", "enabled" => false},
          scheduler: scheduler,
          before_update_persist: fn ->
            send(owner, {:update_ready, self()})
            receive do: (:continue_update -> :ok)
          end
        )
      end)

    assert_receive {:update_ready, updater}, 1_000

    assert {:ok, _terminal} =
             Store.merge_existing(:routine, id, %{
               "last_run_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
               "last_status" => "completed"
             })

    send(updater, :continue_update)
    assert {:ok, %{"name" => "after-race", "enabled" => false}} = Task.await(update)

    assert {:ok, %{"name" => "after-race", "enabled" => false, "last_status" => "completed"}} =
             Store.get(:routine, id)
  end

  test "update cannot recreate a routine deleted after its read" do
    scheduler = isolated_scheduler()

    assert {:ok, %{"id" => id}} =
             Routines.create(routine_attrs("delete-race"), scheduler: scheduler)

    owner = self()

    update =
      Task.async(fn ->
        Routines.update(id, %{"name" => "must-stay-deleted"},
          scheduler: scheduler,
          before_update_persist: fn ->
            send(owner, {:update_ready, self()})
            receive do: (:continue_update -> :ok)
          end
        )
      end)

    assert_receive {:update_ready, updater}, 1_000
    assert :ok = Store.delete(:routine, id)
    send(updater, :continue_update)

    assert {:error, :not_found} = Task.await(update)
    assert {:error, :not_found} = Store.get(:routine, id)
  end

  test "stored trigger reloads by ID, emits after submission, and rejects disabled routines" do
    owner = self()
    name = "stored-trigger-#{System.unique_integer([:positive])}"
    task_supervisor = start_supervised!({Task.Supervisor, []})

    scheduler =
      start_supervised!(
        {LocalScheduler,
         name: String.to_atom("routines_scheduler_#{System.unique_integer([:positive])}"),
         daemon: :test_daemon,
         task_supervisor: task_supervisor,
         config_loader: fn -> Enum.filter(Store.list(:routine), &(&1["name"] == name)) end,
         config_writer: &Store.put/2,
         trigger_fun: fn config, _daemon ->
           send(owner, {:submitted_stored_config, config})

           {:ok,
            %AgentRun{
              id: Ecto.UUID.generate(),
              kind: config["kind"],
              status: "queued",
              routine_id: config["id"],
              prompt: config["prompt"],
              tool_profile: config["tool_profile"] || "assistant_basic"
            }}
         end,
         reload_interval_ms: :timer.hours(1)}
      )

    :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "agent:daemon")

    assert {:ok, %{"id" => id}} =
             Routines.create(Map.put(routine_attrs(name), "tool_profile", "read_only"),
               scheduler: scheduler
             )

    on_exit(fn -> Store.delete(:routine, id) end)

    assert [%{id: ^id, name: ^name}] = LocalScheduler.status(scheduler)

    assert {:ok, %AgentRun{id: run_id, routine_id: ^id}} =
             Routines.trigger(id, scheduler: scheduler)

    assert_receive {:submitted_stored_config,
                    %{"id" => ^id, "tool_profile" => "read_only"} = submitted}

    assert submitted["prompt"] == "#{name} prompt"

    assert_receive {:agent_daemon_event,
                    %{
                      event: "agent.routine.triggered",
                      routine_id: ^id,
                      routine_name: ^name,
                      kind: "schedule",
                      run_id: ^run_id,
                      status: "queued",
                      at: %DateTime{}
                    }}

    assert {:ok, %{"enabled" => false}} =
             Routines.update(id, %{"enabled" => false}, scheduler: scheduler)

    assert {:error, :disabled} = Routines.trigger(id, scheduler: scheduler)
    refute_receive {:agent_daemon_event, %{event: "agent.routine.triggered"}}, 50
  end

  test "merge-PATCH validates legacy heartbeat records before persisting" do
    scheduler = isolated_scheduler()
    id = Ecto.UUID.generate()

    assert {:ok, _heartbeat} =
             Store.put(:heartbeat, %{
               "id" => id,
               "name" => "legacy-heartbeat",
               "schedule" => "0 * * * *",
               "prompt" => "inspect health",
               "enabled" => true
             })

    on_exit(fn -> Store.delete(:heartbeat, id) end)

    assert {:error, %Ecto.Changeset{valid?: false}} =
             Routines.update(id, %{"schedule" => "not a cron"}, scheduler: scheduler)

    assert {:ok, %{"schedule" => "0 * * * *"}} = Store.get(:heartbeat, id)
  end

  defp routine_attrs(name) do
    %{
      "name" => name,
      "kind" => "schedule",
      "enabled" => true,
      "schedule" => "0 2 * * *",
      "prompt" => "#{name} prompt"
    }
  end

  defp isolated_scheduler do
    task_supervisor = start_supervised!({Task.Supervisor, []})

    start_supervised!(
      {LocalScheduler,
       name: String.to_atom("routines_scheduler_#{System.unique_integer([:positive])}"),
       daemon: :test_daemon,
       task_supervisor: task_supervisor,
       config_loader: fn -> [] end,
       config_writer: fn _type, attrs -> {:ok, attrs} end,
       reload_interval_ms: :timer.hours(1)}
    )
  end
end
