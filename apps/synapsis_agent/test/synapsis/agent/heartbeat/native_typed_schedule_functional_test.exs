defmodule Synapsis.Agent.Heartbeat.NativeTypedScheduleFunctionalTest do
  use Synapsis.Agent.DaemonCase, async: false

  alias Synapsis.Agent.Routines
  alias Synapsis.Agent.Heartbeat.LocalScheduler
  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Config.Store, as: ConfigStore
  alias Synapsis.Part.ToolResult
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir

  setup do
    assert {:ok, _} = wait_for_ready()
    assert is_pid(Process.whereis(LocalScheduler))
    :ok
  end

  test "future at fires once, deletes by default, retains durable history and replays the worker",
       ctx do
    fixture = native_fixture(ctx.tmp_dir)
    target = future(2_000)
    config = put_routine(fixture, at(target))
    assert :ok = LocalScheduler.reload()
    assert_slot(config["id"], target)
    run = await_run(config["id"])
    completed = assert_native_run(run, fixture, 1)
    assert DateTime.compare(completed.started_at, target) in [:eq, :gt]
    assert is_binary(completed.idempotency_key)
    assert Runs.get_by_idempotency_key(completed.idempotency_key) == completed

    assert {:ok, :deleted} =
             wait_for(fn ->
               if Enum.all?(ConfigStore.list(:routine), &(&1["id"] != config["id"])),
                 do: {:ok, :deleted},
                 else: :retry
             end)

    assert {:ok, ^completed} = Runs.fetch(completed.id)

    assert Enum.map(Synapsis.Agent.RunEvents.list_for_run(completed.id), & &1["type"]) ==
             ["run.created", "run.starting", "run.started", "run.completed"]

    replace_scheduler()
    assert :ok = LocalScheduler.reload()
    assert routine_runs(config["id"]) == [completed]
    assert_worker_replay(completed, fixture)
    assert {:ok, ^completed} = Runs.fetch(completed.id)
  end

  test "retained one-shot disables after completion and completed-slot reconciliation repeats no effect",
       ctx do
    fixture = native_fixture(ctx.tmp_dir)
    config = put_routine(fixture, at(future(2_000)), %{"deleteAfterRun" => false})
    assert :ok = LocalScheduler.reload()
    completed = config["id"] |> await_run() |> assert_native_run(fixture, 1)
    retained = await_config(config["id"], &(&1["enabled"] == false))
    assert retained["last_status"] == "completed"
    assert retained["id"] == config["id"]
    refute Map.has_key?(retained, "next_run_at")

    # Restore the same persisted schedule identity as a stale pre-terminal snapshot.
    # The durable occurrence must reconcile its completed run rather than execute again.
    assert {:ok, _} = ConfigStore.put(:routine, config)
    replace_scheduler()
    reconciled = await_config(config["id"], &(&1["enabled"] == false))
    refute Map.has_key?(reconciled, "next_run_at")
    assert routine_runs(config["id"]) == [completed]
    assert requests(fixture) |> length() == 2
    assert effect(fixture) == "effect"
  end

  test "overdue at resumes after replacement and an admitted slot survives another replacement",
       ctx do
    fixture = native_fixture(ctx.tmp_dir, hold_first: true)
    stop_scheduler()
    config = put_routine(fixture, at(DateTime.add(DateTime.utc_now(), -1, :second)))
    restart_scheduler()
    assert_receive {:typed_provider_waiting, handler}, 5_000
    run = await_run(config["id"])
    replace_scheduler()
    send(handler, :continue_typed_schedule)
    completed = assert_native_run(run, fixture, 1)
    assert routine_runs(config["id"]) == [completed]
    assert {:ok, ^completed} = Runs.fetch(completed.id)
    assert requests(fixture) |> length() == 2
  end

  test "manual future at preserves its timer through replacement and the scheduled slot still runs",
       ctx do
    fixture = native_fixture(ctx.tmp_dir, automations: true)
    target = future(8_000)
    config = put_routine(fixture, at(target))
    assert :ok = LocalScheduler.reload()
    assert {:ok, manual} = Routines.trigger({"routine", config["id"]})
    manual = assert_native_run(manual, fixture, 1)
    assert_typed_automation_results(manual, fixture, config["schedule"])
    assert {:ok, %{"enabled" => true}} = ConfigStore.get(:routine, config["id"])
    assert_slot(config["id"], target)
    replace_scheduler()
    assert_slot(config["id"], target)
    assert routine_runs(config["id"]) == [manual]
    scheduled = await_run(config["id"], [manual.id], 12_000)
    scheduled = assert_native_run(scheduled, fixture, 2)
    assert scheduled.id != manual.id
    assert DateTime.compare(scheduled.started_at, target) in [:eq, :gt]
    assert length(routine_runs(config["id"])) == 2
  end

  test "manual due at consumes its single occurrence", ctx do
    fixture = native_fixture(ctx.tmp_dir)
    config = put_routine(fixture, at(DateTime.add(DateTime.utc_now(), -1, :second)))
    assert {:ok, submitted} = Routines.trigger({"routine", config["id"]})
    completed = assert_native_run(submitted, fixture, 1)

    assert {:ok, :consumed} =
             wait_for(fn ->
               if Enum.all?(ConfigStore.list(:routine), &(&1["id"] != config["id"])),
                 do: {:ok, :consumed},
                 else: :retry
             end)

    replace_scheduler()
    assert routine_runs(config["id"]) == [completed]
    assert requests(fixture) |> length() == 2
  end

  test "short scheduled interval advances from actual run start and manual recurring preserves its slot",
       ctx do
    fixture = native_fixture(ctx.tmp_dir)
    anchor = future(2_000)
    period = 8_000
    config = put_routine(fixture, every(period, anchor))
    assert :ok = LocalScheduler.reload()
    scheduled = config["id"] |> await_run() |> assert_native_run(fixture, 1)
    expected = DateTime.add(scheduled.started_at, period, :millisecond)
    assert_slot(config["id"], expected)

    assert {:ok, manual} = Routines.trigger({"routine", config["id"]})
    assert_native_run(manual, fixture, 2)
    assert :ok = LocalScheduler.reload()
    assert_slot(config["id"], expected)
    replace_scheduler()
    assert_slot(config["id"], expected)
    assert {:ok, _} = Routines.update({"routine", config["id"]}, %{"enabled" => false})
  end

  test "long interval execution returns to the original anchor grid", ctx do
    fixture = native_fixture(ctx.tmp_dir, hold_first: true)
    anchor = future(1_000)
    period = 1_000
    config = put_routine(fixture, every(period, anchor))
    assert :ok = LocalScheduler.reload()
    assert_receive {:typed_provider_waiting, handler}, 5_000
    run = await_run(config["id"])

    assert {:ok, :elapsed} =
             wait_for(fn ->
               if System.system_time(:millisecond) >=
                    DateTime.to_unix(run.started_at, :millisecond) + 2_200,
                  do: {:ok, :elapsed},
                  else: :retry
             end)

    send(handler, :continue_typed_schedule)
    completed = assert_native_run(run, fixture, 1)
    persisted = await_config(config["id"], &(&1["last_status"] == "completed"))
    next = parse!(persisted["next_run_at"])
    assert DateTime.compare(next, completed.finished_at) == :gt

    assert rem(
             DateTime.to_unix(next, :millisecond) - DateTime.to_unix(anchor, :millisecond),
             period
           ) == 0

    assert DateTime.diff(next, completed.finished_at, :millisecond) <= period
    assert {:ok, _} = Routines.update({"routine", config["id"]}, %{"enabled" => false})
  end

  test "restart admits a persisted due recurring slot and an edit survives its older terminal result",
       ctx do
    fixture = native_fixture(ctx.tmp_dir, hold_first: true)
    stop_scheduler()
    due = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:millisecond)

    config =
      put_routine(fixture, every(60_000, future(60_000)), %{
        "next_run_at" => DateTime.to_iso8601(due)
      })

    assert {:ok, _} =
             ConfigStore.put(:heartbeat, %{
               "id" => config["id"],
               "name" => "Same UUID legacy heartbeat",
               "kind" => "heartbeat",
               "enabled" => true,
               "schedule" => "0 0 1 1 *",
               "timezone" => "Asia/Kathmandu",
               "agent_name" => fixture.agent.name,
               "tool_profile" => "native_agent",
               "prompt" => "Perform the legacy scheduled work"
             })

    restart_scheduler()
    assert_receive {:typed_provider_waiting, handler}, 5_000
    run = await_run(config["id"])
    assert DateTime.compare(run.scheduled_for, due) == :eq

    assert {:ok, sibling} =
             wait_for(fn ->
               case ConfigStore.get(:heartbeat, config["id"]) do
                 {:ok, %{"next_run_at" => next} = saved} when is_binary(next) -> {:ok, saved}
                 _ -> :retry
               end
             end)

    sibling_timer = :sys.get_state(LocalScheduler).timers[{"heartbeat", config["id"]}]
    replacement_target = future(60_000)
    replacement = at(replacement_target)
    assert {:ok, _} = Routines.update({"routine", config["id"]}, %{"schedule" => replacement})
    assert_slot(config["id"], replacement_target)
    send(handler, :continue_typed_schedule)
    assert_native_run(run, fixture, 1)
    assert :ok = LocalScheduler.reload()
    assert {:ok, current} = ConfigStore.get(:routine, config["id"])
    assert current["schedule"] == replacement
    assert current["enabled"]
    assert_slot(config["id"], replacement_target)
    assert {:ok, ^sibling} = ConfigStore.get(:heartbeat, config["id"])
    assert :sys.get_state(LocalScheduler).timers[{"heartbeat", config["id"]}] == sibling_timer
    assert {:ok, _} = Routines.update({"routine", config["id"]}, %{"enabled" => false})
  end

  test "file edited one-shot keeps its replacement after the older scheduled run completes",
       ctx do
    fixture = native_fixture(ctx.tmp_dir, hold_first: true)
    original = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:millisecond)
    config = put_routine(fixture, at(original))
    assert :ok = LocalScheduler.reload()
    assert_receive {:typed_provider_waiting, handler}, 5_000
    run = await_run(config["id"])
    replacement_target = future(60_000)
    replacement = at(replacement_target)
    path = ConfigStore.file_path(:routine)
    before = File.read!(path)

    edited =
      String.replace(
        before,
        ~s("schedule"."at" = ) <> inspect(config["schedule"]["at"]),
        ~s("schedule"."at" = ) <> inspect(replacement["at"])
      )

    assert edited != before
    File.write!(path, edited)
    assert :ok = ConfigStore.reload(:routine)
    assert {:ok, changed} = ConfigStore.get(:routine, config["id"])
    assert changed["schedule_generation"] != config["schedule_generation"]
    assert :ok = LocalScheduler.reload()
    assert_slot(config["id"], replacement_target)
    send(handler, :continue_typed_schedule)
    completed = assert_native_run(run, fixture, 1)
    assert :ok = LocalScheduler.reload()
    assert {:ok, current} = ConfigStore.get(:routine, config["id"])
    assert current["schedule"] == replacement
    assert current["enabled"]
    assert current["schedule_generation"] == changed["schedule_generation"]
    assert_slot(config["id"], replacement_target)
    assert routine_runs(config["id"]) == [completed]
    assert {:ok, _} = Routines.update({"routine", config["id"]}, %{"enabled" => false})
  end

  test "prefeature cron completion preserves a typed replacement after ordinary legacy state writes",
       ctx do
    fixture = native_fixture(ctx.tmp_dir, hold_first: true)
    config = put_routine(fixture, "0 0 1 1 *")
    :ets.delete(:synapsis_config_routine, config["id"])
    assert :ok = ConfigStore.reload(:routine)
    assert {:ok, original} = ConfigStore.get(:routine, config["id"])
    refute Map.has_key?(original, "schedule_generation")
    assert :ok = LocalScheduler.reload()
    assert {:ok, run} = Routines.trigger({"routine", config["id"]})
    assert_receive {:typed_provider_waiting, handler}, 5_000
    legacy_state = await_config(config["id"], &is_binary(&1["next_run_at"]))
    assert legacy_state["schedule"] == original["schedule"]
    refute Map.has_key?(legacy_state, "schedule_generation")
    target = future(60_000)
    replacement = at(target)

    assert {:ok, changed} =
             Routines.update({"routine", config["id"]}, %{"schedule" => replacement})

    assert is_binary(changed["schedule_generation"])
    assert_slot(config["id"], target)
    send(handler, :continue_typed_schedule)
    assert_native_run(run, fixture, 1)

    assert {:ok, :settled} =
             wait_for(fn ->
               state = :sys.get_state(LocalScheduler)
               key = {"routine", config["id"]}

               if state.terminal_events[run.id] == :persisted and
                    not Enum.any?(state.persistence_tasks, fn {_ref, task} -> task.key == key end) and
                    not Map.has_key?(state.pending_persistence, key),
                  do: {:ok, :settled},
                  else: :retry
             end)

    status =
      Enum.find(
        LocalScheduler.status(LocalScheduler),
        &(&1.id == config["id"] and &1.source == "routine")
      )

    assert status.last_status == "completed"
    assert status.last_error == nil
    assert :ok = LocalScheduler.reload()
    assert {:ok, current} = ConfigStore.get(:routine, config["id"])
    assert current["schedule"] == replacement
    assert current["schedule_generation"] == changed["schedule_generation"]
    assert current["enabled"]
    assert_slot(config["id"], target)
    assert {:ok, _} = Routines.update({"routine", config["id"]}, %{"enabled" => false})
  end

  test "typed cron reports its own zone and retains its timer across unchanged reload", ctx do
    fixture = native_fixture(ctx.tmp_dir)
    schedule = %{"kind" => "cron", "expr" => "0 0 1 1 *", "tz" => "Asia/Kathmandu"}
    config = put_routine(fixture, schedule, %{"timezone" => "Etc/UTC"})

    assert {:ok, expected} =
             Synapsis.Agent.Heartbeat.Schedule.next_after(schedule, "Etc/UTC", DateTime.utc_now())

    assert :ok = LocalScheduler.reload()
    assert_slot(config["id"], expected)
    key = {"routine", config["id"]}
    timer = :sys.get_state(LocalScheduler).timers[key]
    assert timer.timezone == "Asia/Kathmandu"

    status =
      Enum.find(
        LocalScheduler.status(LocalScheduler),
        &(&1.id == config["id"] and &1.source == "routine")
      )

    assert status.timezone == "Asia/Kathmandu"
    assert DateTime.compare(status.next_run_at, expected) == :eq
    assert :ok = LocalScheduler.reload()
    assert :sys.get_state(LocalScheduler).timers[key] == timer
    assert requests(fixture) == []
  end

  defp native_fixture(root, opts \\ []) do
    http = Gaoxy.Test.open()
    provider = "typed-schedule-#{Ecto.UUID.generate()}"
    owner = self()
    log = start_supervised!({Agent, fn -> [] end})

    assert :ok =
             Synapsis.Provider.Registry.register(provider, %{
               type: "openai",
               api_key: "test-key",
               base_url: String.trim_trailing(Gaoxy.Test.url(http), "/")
             })

    tools =
      if opts[:automations], do: ["exec_command", "synapsis::automations"], else: ["exec_command"]

    assert {:ok, saved} =
             Synapsis.AgentConfigs.create(%{
               name: provider,
               provider: provider,
               model: "typed-schedule-model",
               tools: tools,
               tool_contract_version: 1,
               config: %{"workspace_path" => root}
             })

    Gaoxy.Test.stub(http, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      number =
        Agent.get_and_update(log, fn previous -> {length(previous) + 1, previous ++ [request]} end)

      following? = Enum.any?(request["messages"], &(&1["role"] == "tool"))

      if number == 1 and Keyword.get(opts, :hold_first, false) do
        send(owner, {:typed_provider_waiting, self()})

        receive do
          :continue_typed_schedule -> :ok
        after
          10_000 -> raise "typed schedule provider was not released"
        end
      end

      tool_ids =
        for message <- request["messages"], message["role"] == "tool", do: message["tool_call_id"]

      chunks =
        cond do
          Keyword.get(opts, :automations, false) and
              not Enum.any?(tool_ids, &String.starts_with?(&1, "typed-list-")) ->
            [
              DeterministicProvider.tool_call_chunk(
                Synapsis.Provider.ToolName.encode("synapsis::automations"),
                "typed-list-#{number}",
                %{"action" => "list"}
              ),
              DeterministicProvider.finish_chunk("tool_calls")
            ]

          Keyword.get(opts, :automations, false) and
              not Enum.any?(tool_ids, &String.starts_with?(&1, "typed-get-")) ->
            config = Enum.find(ConfigStore.list(:routine), &(&1["agent_name"] == saved.name))

            [
              DeterministicProvider.tool_call_chunk(
                Synapsis.Provider.ToolName.encode("synapsis::automations"),
                "typed-get-#{number}",
                %{"action" => "get", "source" => "routine", "id" => config["id"]}
              ),
              DeterministicProvider.finish_chunk("tool_calls")
            ]

          (not Keyword.get(opts, :automations, false) and following?) or
              Enum.any?(tool_ids, &String.starts_with?(&1, "typed-effect-")) ->
            [
              DeterministicProvider.text_chunk("Scheduled work completed"),
              DeterministicProvider.finish_chunk("stop")
            ]

          true ->
            [
              DeterministicProvider.tool_call_chunk("exec_command", "typed-effect-#{number}", %{
                "cmd" => "printf effect >> typed-schedule-effect.txt",
                "login" => false,
                "yield_time_ms" => 1000
              }),
              DeterministicProvider.finish_chunk("tool_calls")
            ]
        end

      DeterministicProvider.send_sse(conn, chunks)
    end)

    on_exit(fn ->
      ensure_scheduler_started()

      for type <- [:routine, :heartbeat],
          config <- ConfigStore.list(type),
          config["agent_name"] == saved.name,
          do: ConfigStore.delete(type, config["id"])

      LocalScheduler.reload()

      for run <- Runs.list_recent(limit: 100),
          run.assistant_name == saved.name,
          is_binary(run.session_id),
          do: Synapsis.Sessions.delete(run.session_id)

      Synapsis.AgentConfigs.delete(saved)
      Synapsis.Provider.Registry.unregister(provider)
    end)

    %{agent: saved, log: log, root: root, tools: tools}
  end

  defp put_routine(fixture, schedule, extra \\ %{}) do
    attrs =
      Map.merge(
        %{
          "id" => Ecto.UUID.generate(),
          "name" => "Typed native schedule",
          "kind" => "heartbeat",
          "enabled" => true,
          "schedule" => schedule,
          "agent_name" => fixture.agent.name,
          "tool_profile" => "native_agent",
          "prompt" => "Perform the scheduled effect",
          "no_overlap" => true,
          "max_runtime_ms" => 30_000
        },
        extra
      )

    assert {:ok, saved} = ConfigStore.put(:routine, attrs)
    saved
  end

  defp assert_native_run(run, fixture, effects) do
    assert {:ok, completed} = wait_for_run(run.id, "completed")
    assert completed.tool_profile == "native_agent"
    assert completed.assistant_name == fixture.agent.name
    assert completed.capability_snapshot["agent_id"] == fixture.agent.id
    assert Enum.sort(completed.capability_snapshot["tool_names"]) == fixture.tools

    assert completed.metadata["automation_ref"] == %{
             "source" => "routine",
             "id" => completed.routine_id
           }

    assert effect(fixture) == String.duplicate("effect", effects)

    results =
      for message <- Synapsis.Sessions.get_messages(completed.session_id),
          %ToolResult{} = part <- message.parts,
          do: part

    assert length(results) == if(length(fixture.tools) == 2, do: 3, else: 1)
    assert Enum.all?(results, &(&1.is_error == false))
    result = List.last(results)

    assert Enum.any?(requests(fixture), fn request ->
             %{
               "role" => "tool",
               "tool_call_id" => result.tool_use_id,
               "content" => result.content
             } in request["messages"]
           end)

    first =
      Enum.find(requests(fixture), fn request ->
        not Enum.any?(request["messages"], &(&1["role"] == "tool"))
      end)

    assert Enum.sort(Enum.map(first["tools"], & &1["function"]["name"])) ==
             Enum.sort(Enum.map(fixture.tools, &Synapsis.Provider.ToolName.encode/1))

    assert {:ok, turns} = Store.list_turns(completed.session_id)

    assert Enum.any?(for(turn <- turns, part <- turn.parts, do: part), fn part ->
             part[:type] == "tool_result" and part[:content] == result.content
           end)

    assert {:ok, ^completed} = Runs.fetch(completed.id)
    completed
  end

  defp assert_typed_automation_results(run, fixture, schedule) do
    parts =
      for message <- Synapsis.Sessions.get_messages(run.session_id),
          %ToolResult{} = part <- message.parts,
          do: part

    [listed, fetched, _effect] = parts
    page = listed.projection["result"]["structured"]
    entry = fetched.projection["result"]["structured"]["routine"]
    assert entry["schedule"] == schedule
    assert entry["source"] == "routine"
    assert entry["id"] == run.routine_id
    assert entry in page["routines"]

    assert Enum.sort(Map.keys(entry)) ==
             ["agent_name", "enabled", "id", "kind", "name", "schedule", "source", "timezone"]

    assert {:ok, turns} = Store.list_turns(run.session_id)

    for part <- [listed, fetched] do
      assert Enum.any?(requests(fixture), fn request ->
               %{"role" => "tool", "tool_call_id" => part.tool_use_id, "content" => part.content} in request[
                 "messages"
               ]
             end)

      assert Enum.any?(for(turn <- turns, stored <- turn.parts, do: stored), fn stored ->
               stored[:projection] == part.projection and stored[:content] == part.content
             end)
    end
  end

  defp assert_worker_replay(run, fixture) do
    session_id = run.session_id
    SessionHarness.subscribe!(session_id)
    SessionHarness.ensure_running!(session_id)
    [{old_worker, _}] = Registry.lookup(Synapsis.Session.Registry, session_id)

    parts =
      for message <- Synapsis.Sessions.get_messages(session_id),
          %ToolResult{} = part <- message.parts,
          do: part

    old_requests = length(requests(fixture))
    monitor = Process.monitor(old_worker)
    assert :ok = DynamicSupervisor.stop_session(session_id)
    assert_receive {:DOWN, ^monitor, :process, ^old_worker, _}, 5_000
    SessionHarness.ensure_running!(session_id)
    [{new_worker, _}] = Registry.lookup(Synapsis.Session.Registry, session_id)
    assert new_worker != old_worker
    assert :ok = Worker.send_message(session_id, "Recall the completed scheduled work")
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert length(requests(fixture)) == old_requests + 1
    replay = List.last(requests(fixture))

    for part <- parts do
      assert %{"role" => "tool", "tool_call_id" => part.tool_use_id, "content" => part.content} in replay[
               "messages"
             ]
    end

    assert for(
             message <- Synapsis.Sessions.get_messages(session_id),
             %ToolResult{} = part <- message.parts,
             do: part
           ) == parts

    assert effect(fixture) == "effect"
    assert :ok = DynamicSupervisor.stop_session(session_id)
  end

  defp assert_slot(id, expected) do
    await_config(id, fn config ->
      case DateTime.from_iso8601(config["next_run_at"] || "") do
        {:ok, actual, 0} -> DateTime.compare(actual, expected) == :eq
        _ -> false
      end
    end)

    assert {:ok, entry} =
             wait_for(fn ->
               case Enum.find(
                      LocalScheduler.status(LocalScheduler),
                      &(&1.id == id and &1.source == "routine")
                    ) do
                 %{next_run_at: next} = entry ->
                   if DateTime.compare(next, expected) == :eq, do: {:ok, entry}, else: :retry

                 _ ->
                   :retry
               end
             end)

    assert entry.next_run_at.time_zone == "Etc/UTC"
  end

  defp await_config(id, predicate) do
    assert {:ok, config} =
             wait_for(fn ->
               case ConfigStore.get(:routine, id) do
                 {:ok, config} -> if predicate.(config), do: {:ok, config}, else: :retry
                 _ -> :retry
               end
             end)

    config
  end

  defp await_run(id, excluded \\ [], timeout \\ 5_000) do
    assert {:ok, run} =
             wait_for(
               fn ->
                 case Enum.find(routine_runs(id), &(&1.id not in excluded)) do
                   nil -> :retry
                   run -> {:ok, run}
                 end
               end,
               timeout
             )

    run
  end

  defp routine_runs(id), do: Enum.filter(Runs.list_recent(limit: 100), &(&1.routine_id == id))
  defp requests(fixture), do: Agent.get(fixture.log, & &1)
  defp effect(fixture), do: File.read!(Path.join(fixture.root, "typed-schedule-effect.txt"))

  defp future(ms),
    do: DateTime.utc_now() |> DateTime.add(ms, :millisecond) |> DateTime.truncate(:millisecond)

  defp at(target), do: %{"kind" => "at", "at" => DateTime.to_iso8601(target)}

  defp every(period, anchor),
    do: %{
      "kind" => "every",
      "everyMs" => period,
      "anchorMs" => DateTime.to_unix(anchor, :millisecond)
    }

  defp parse!(encoded), do: elem(DateTime.from_iso8601(encoded), 1)

  defp stop_scheduler do
    old = Process.whereis(LocalScheduler)
    monitor = Process.monitor(old)
    assert :ok = Supervisor.terminate_child(SynapsisCore.Supervisor, LocalScheduler)
    assert_receive {:DOWN, ^monitor, :process, ^old, _}, 5_000
  end

  defp restart_scheduler do
    assert {:ok, _} = Supervisor.restart_child(SynapsisCore.Supervisor, LocalScheduler)
    assert :ok = LocalScheduler.reload()
  end

  defp replace_scheduler do
    stop_scheduler()
    restart_scheduler()
  end

  defp ensure_scheduler_started do
    if is_nil(Process.whereis(LocalScheduler)),
      do: Supervisor.restart_child(SynapsisCore.Supervisor, LocalScheduler)
  end
end
