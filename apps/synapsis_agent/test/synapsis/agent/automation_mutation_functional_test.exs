defmodule Synapsis.Agent.AutomationMutationFunctionalTest do
  use Synapsis.Agent.DaemonCase, async: false
  @moduletag :functional

  alias Synapsis.Agent.Heartbeat.LocalScheduler
  alias Synapsis.Agent.Routines
  alias Synapsis.Config.Store

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    previous = System.get_env("SYNAPSIS_CONFIG_DIR")

    snapshots =
      for type <- [:routine, :heartbeat] do
        [{pid, _}] = Registry.lookup(Synapsis.Config.Store.Registry, type)
        table = String.to_existing_atom("synapsis_config_#{type}")
        {type, pid, table, :ets.tab2list(table), :sys.get_state(pid).load_error}
      end

    System.put_env("SYNAPSIS_CONFIG_DIR", root)

    for {type, _, _, _, _} <- snapshots do
      File.write!(Store.file_path(type), "")
      assert :ok = Store.reload(type)
    end

    assert :ok = LocalScheduler.reload()
    Application.put_env(:synapsis_agent, :daemon_fake_session_mode, :waiting)

    on_exit(fn ->
      if previous,
        do: System.put_env("SYNAPSIS_CONFIG_DIR", previous),
        else: System.delete_env("SYNAPSIS_CONFIG_DIR")

      for {_, pid, table, entries, error} <- snapshots do
        :ets.delete_all_objects(table)
        :ets.insert(table, entries)
        :sys.replace_state(pid, &Map.put(&1, :load_error, error))
      end

      LocalScheduler.reload()
    end)

    %{
      context: %{
        creator_agent_id: Ecto.UUID.generate(),
        session_id: Ecto.UUID.generate(),
        requester_name: "main"
      }
    }
  end

  test "a later same-Agent session patches the latest versioned entry without rebinding its source",
       ctx do
    routine = versioned(ctx.context)
    assert {:ok, _} = Store.put(:routine, routine)
    scheduler = scheduler()
    original = saved_with_slot(routine["id"])
    origin = original["automation_origin"]
    slot = original["next_run_at"]
    generation = original["schedule_generation"]

    assert {:ok, _} =
             Store.merge_existing(:routine, routine["id"], %{
               "vendor_note" => %{"label" => "latest value", "rank" => 0},
               "delivery" => %{"unknown" => false, "rank" => 0}
             })

    patch = %{
      "name" => "Edited display",
      "prompt" => "\n  Exact edited prompt  \n",
      "agent_name" => "changed-execution-route",
      "no_overlap" => false,
      "provider" => nil,
      "delivery" => %{"mode" => "none"}
    }

    assert {:ok, receipt} =
             Routines.update_automation(
               {"routine", routine["id"]},
               patch,
               later_session(ctx.context),
               scheduler: scheduler
             )

    assert receipt.source == "routine"
    assert receipt.id == routine["id"]
    assert receipt.persisted
    assert receipt.activation == "reloaded"
    assert receipt.cancellation == %{status: :not_requested, cleanup_pending: false}
    assert {:ok, saved} = Store.get(:routine, routine["id"])
    assert saved["automation_origin"] == origin
    assert saved["automation_contract_version"] == 1
    assert saved["session_target"] == "isolated"
    assert saved["name"] == patch["name"]
    assert saved["prompt"] == patch["prompt"]
    assert saved["agent_name"] == patch["agent_name"]
    assert saved["no_overlap"] == false
    assert saved["vendor_note"] == %{"label" => "latest value", "rank" => 0}
    assert saved["delivery"] == %{"mode" => "none", "unknown" => false, "rank" => 0}
    assert Map.has_key?(saved, "provider") == false
    assert saved["model"] == "kept-model"
    assert saved["createdAtMs"] == original["createdAtMs"]
    assert saved["schedule_generation"] == generation
    assert saved["next_run_at"] == slot

    assert {:ok, second} =
             Routines.update_automation(
               {"routine", routine["id"]},
               %{"model" => nil},
               later_session(ctx.context),
               scheduler: scheduler
             )

    assert second.activation == "reloaded"
    assert {:ok, final} = Store.get(:routine, routine["id"])
    assert Map.has_key?(final, "model") == false
    assert final["name"] == patch["name"]
    assert final["prompt"] == patch["prompt"]
    assert final["delivery"] == saved["delivery"]
    assert final["schedule_generation"] == generation
    assert final["next_run_at"] == slot
    assert final["automation_origin"] == origin
    assert :ok = Store.reload(:routine)
    assert {:ok, ^final} = Store.get(:routine, routine["id"])
  end

  test "versioned cadence edits use serialized defaults and preserve explicit zero and false",
       ctx do
    routine = versioned(ctx.context, %{"enabled" => false})
    assert {:ok, original} = Store.put(:routine, routine)
    scheduler = scheduler()
    before_ms = System.system_time(:millisecond)

    assert {:ok, changed} =
             Routines.update_automation(
               {"routine", routine["id"]},
               %{"schedule" => %{"kind" => "every", "everyMs" => 7_200_000}},
               later_session(ctx.context),
               scheduler: scheduler
             )

    after_ms = System.system_time(:millisecond)
    assert changed.activation == "reloaded"
    assert changed.cancellation.status == :not_requested
    assert changed.routine["enabled"] == false
    assert changed.routine["schedule"]["anchorMs"] in before_ms..after_ms
    assert changed.routine["schedule_generation"] != original["schedule_generation"]
    assert changed.routine["createdAtMs"] == original["createdAtMs"]
    assert changed.routine["automation_origin"] == original["automation_origin"]

    assert {:ok, cron} =
             Routines.update_automation(
               {"routine", routine["id"]},
               %{"schedule" => %{"kind" => "cron", "expr" => "0 * * * *"}},
               later_session(ctx.context),
               scheduler: scheduler
             )

    assert cron.routine["schedule"]["staggerMs"] == 300_000

    assert {:ok, zero} =
             Routines.update_automation(
               {"routine", routine["id"]},
               %{
                 "schedule" => %{"kind" => "cron", "expr" => "0 * * * *", "staggerMs" => 0},
                 "deleteAfterRun" => false,
                 "no_overlap" => false
               },
               later_session(ctx.context),
               scheduler: scheduler
             )

    assert zero.routine["schedule"]["staggerMs"] == 0
    assert zero.routine["enabled"] == false
    assert zero.routine["deleteAfterRun"] == false
    assert zero.routine["no_overlap"] == false
    assert zero.routine["automation_origin"] == original["automation_origin"]
    assert :sys.get_state(scheduler).timers[{"routine", routine["id"]}] == nil
  end

  for source <- ["routine", "heartbeat"] do
    test "legacy #{source} edits retain routing fallback and same-UUID source identity", ctx do
      legacy_edit(unquote(source), ctx)
    end
  end

  test "an update disabling a versioned automation cancels captured work and retains later force work",
       ctx do
    {routine, scheduler} = lifecycle_fixture(ctx.context)
    target = {"routine", routine["id"]}
    sibling_target = {"heartbeat", routine["id"]}
    assert {:ok, active} = Routines.trigger(target, scheduler: scheduler)
    assert_receive {:waiting_session, _}, 2_000
    assert {:ok, _} = wait_for_run(active.id, "running")
    assert {:ok, queued} = Routines.trigger(target, scheduler: scheduler)
    assert {:ok, sibling} = Routines.trigger(sibling_target, scheduler: scheduler)

    assert {:ok, disabled} =
             Routines.update_automation(
               target,
               %{"enabled" => false, "name" => "Disabled together", "prompt" => "Fresh prompt"},
               later_session(ctx.context),
               scheduler: scheduler
             )

    assert disabled.persisted
    assert disabled.activation == "retired"
    assert disabled.cancellation.status == :cancellation_requested
    assert disabled.cancellation.active_count == 1
    assert disabled.cancellation.queued_count == 1
    assert disabled.routine["enabled"] == false
    assert disabled.routine["name"] == "Disabled together"
    assert disabled.routine["prompt"] == "Fresh prompt"
    assert disabled.routine["automation_origin"] == routine["automation_origin"]
    assert :sys.get_state(scheduler).timers[target] == nil
    assert :sys.get_state(scheduler).timers[sibling_target] != nil
    assert {:ok, _} = wait_for_run(active.id, "cancelled")
    assert {:ok, _} = wait_for_run(queued.id, "cancelled")
    assert_receive {:waiting_session, sibling_session}, 2_000
    complete_session(sibling_session)
    assert {:ok, _} = wait_for_run(sibling.id, "completed")

    assert {:ok, %{enqueued: true, run: forced}} =
             Routines.run(target, :force, scheduler: scheduler)

    assert_receive {:waiting_session, forced_session}, 2_000
    assert {:ok, _} = wait_for_run(forced.id, "running")

    assert {:ok, repeated} =
             Routines.update_automation(
               target,
               %{"enabled" => false, "name" => "Still disabled"},
               later_session(ctx.context),
               scheduler: scheduler
             )

    assert repeated.persisted
    assert repeated.activation == "reloaded"
    assert repeated.cancellation == %{status: :not_requested, cleanup_pending: false}
    assert Runs.get(forced.id).status == "running"
    complete_session(forced_session)
    assert {:ok, _} = wait_for_run(forced.id, "completed")
    assert {:ok, saved} = Store.get(:routine, routine["id"])
    assert saved["enabled"] == false
    assert saved["name"] == "Still disabled"
    assert saved["automation_origin"] == routine["automation_origin"]
  end

  test "a later same-Agent session removes its original automation through the managed owner",
       ctx do
    {routine, scheduler} = lifecycle_fixture(ctx.context)
    target = {"routine", routine["id"]}
    sibling_target = {"heartbeat", routine["id"]}
    assert {:ok, active} = Routines.trigger(target, scheduler: scheduler)
    assert_receive {:waiting_session, _}, 2_000
    assert {:ok, queued} = Routines.trigger(target, scheduler: scheduler)
    assert {:ok, sibling} = Routines.trigger(sibling_target, scheduler: scheduler)

    assert {:ok, removed} =
             Routines.remove_automation(target, later_session(ctx.context), scheduler: scheduler)

    assert removed.source == "routine"
    assert removed.id == routine["id"]
    assert removed.persisted
    assert removed.removed
    assert removed.activation == "retired"
    assert removed.cancellation.status == :cancellation_requested
    assert removed.cancellation.active_count == 1
    assert removed.cancellation.queued_count == 1
    assert {:error, :not_found} = Store.get(:routine, routine["id"])
    assert {:ok, sibling_config} = Store.get(:heartbeat, routine["id"])
    assert sibling_config["enabled"]
    assert :sys.get_state(scheduler).timers[target] == nil
    assert :sys.get_state(scheduler).timers[sibling_target] != nil
    assert {:ok, _} = wait_for_run(active.id, "cancelled")
    assert {:ok, _} = wait_for_run(queued.id, "cancelled")
    assert_receive {:waiting_session, sibling_session}, 2_000
    complete_session(sibling_session)
    assert {:ok, _} = wait_for_run(sibling.id, "completed")
    assert {:ok, _} = Runs.fetch(active.id)
    assert {:ok, _} = Runs.fetch(queued.id)
  end

  defp legacy_edit(source, ctx) do
    id = Ecto.UUID.generate()
    other = if source == "routine", do: "heartbeat", else: "routine"
    original = legacy(id, source)
    assert {:ok, _} = Store.put(String.to_existing_atom(source), original)
    assert {:ok, _} = Store.put(String.to_existing_atom(other), legacy(id, other))
    scheduler = scheduler()
    assert {:ok, sibling} = Store.get(String.to_existing_atom(other), id)

    assert {:ok, receipt} =
             Routines.update_automation(
               {source, id},
               %{
                 "name" => "Edited legacy display",
                 "prompt" => "\n Legacy bytes  \n",
                 "schedule" => "30 0 1 1 *",
                 "timezone" => "Asia/Shanghai",
                 "no_overlap" => false
               },
               later_session(ctx.context),
               scheduler: scheduler
             )

    assert receipt.source == source
    assert receipt.id == id
    assert receipt.persisted
    assert receipt.activation == "reloaded"
    assert receipt.cancellation.status == :not_requested
    assert {:ok, saved} = Store.get(String.to_existing_atom(source), id)
    assert saved["name"] == "Edited legacy display"
    assert saved["prompt"] == "\n Legacy bytes  \n"
    assert saved["schedule"] == "30 0 1 1 *"
    assert saved["timezone"] == "Asia/Shanghai"
    assert saved["no_overlap"] == false
    assert saved["vendor_note"] == original["vendor_note"]
    assert Map.has_key?(saved, "automation_origin") == false
    assert Map.has_key?(saved, "automation_contract_version") == false
    assert {:ok, ^sibling} = Store.get(String.to_existing_atom(other), id)
    assert :ok = Store.reload(String.to_existing_atom(source))
    assert {:ok, ^saved} = Store.get(String.to_existing_atom(source), id)
  end

  defp versioned(context, extra \\ %{}) do
    %{
      "id" => Ecto.UUID.generate(),
      "name" => "Original display",
      "kind" => "schedule",
      "prompt" => "Original prompt",
      "agent_name" => "main",
      "enabled" => true,
      "tool_profile" => "assistant_basic",
      "no_overlap" => true,
      "automation_contract_version" => 1,
      "automation_origin" => %{
        "agent_id" => context.creator_agent_id,
        "session_id" => context.session_id
      },
      "session_target" => "isolated",
      "delivery" => %{"mode" => "none"},
      "provider" => "kept-provider",
      "model" => "kept-model",
      "schedule" => %{"kind" => "every", "everyMs" => 3_600_000, "anchorMs" => 0}
    }
    |> Map.merge(extra)
  end

  defp legacy(id, source) do
    %{
      "id" => id,
      "name" => "Legacy display",
      "agent_name" => "main",
      "prompt" => "Legacy prompt",
      "enabled" => true,
      "tool_profile" => "assistant_basic",
      "no_overlap" => false,
      "schedule" => "0 0 1 1 *",
      "vendor_note" => %{"source" => source, "retained" => true}
    }
    |> then(fn attrs ->
      if source == "routine", do: Map.put(attrs, "kind", "schedule"), else: attrs
    end)
  end

  defp lifecycle_fixture(context) do
    routine =
      versioned(context, %{"no_overlap" => false})
      |> Map.drop(["provider", "model"])

    assert {:ok, saved} = Store.put(:routine, routine)
    assert {:ok, _} = Store.put(:heartbeat, legacy(routine["id"], "heartbeat"))
    {saved, scheduler()}
  end

  defp scheduler do
    {daemon, supervisor} = start_test_daemon(sessions: FakeSessions)
    name = String.to_atom("automation_mutation_scheduler_#{System.unique_integer([:positive])}")

    start_supervised!(
      {LocalScheduler,
       name: name, daemon: daemon, task_supervisor: supervisor, reload_interval_ms: 60_000}
    )

    assert :ok = LocalScheduler.reload(name)

    assert {:ok, :persisted} =
             wait_for(fn ->
               state = :sys.get_state(name)

               if state.persistence_tasks == %{} and state.pending_persistence == %{},
                 do: {:ok, :persisted},
                 else: :retry
             end)

    name
  end

  defp saved_with_slot(id) do
    assert {:ok, saved} =
             wait_for(fn ->
               case Store.get(:routine, id) do
                 {:ok, %{"next_run_at" => next} = saved} when is_binary(next) -> {:ok, saved}
                 _ -> :retry
               end
             end)

    saved
  end

  defp later_session(context), do: %{context | session_id: Ecto.UUID.generate()}

  defp complete_session(id),
    do: Phoenix.PubSub.broadcast(Synapsis.PubSub, "session:#{id}", {"done", %{}})
end
