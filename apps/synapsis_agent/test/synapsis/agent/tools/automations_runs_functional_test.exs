defmodule Synapsis.Agent.Tools.AutomationsRunsFunctionalTest do
  use Synapsis.Agent.DaemonCase, async: false
  @moduletag :functional

  alias Synapsis.Agent.Heartbeat.LocalScheduler
  alias Synapsis.Agent.TestSupport.DeterministicProvider, as: Provider
  alias Synapsis.Config.Store, as: ConfigStore
  alias Synapsis.Part.ToolResult
  alias Synapsis.Session.Store

  @moduletag :tmp_dir
  setup ctx do
    previous = System.get_env("SYNAPSIS_WORKSPACE_ROOT")
    System.put_env("SYNAPSIS_WORKSPACE_ROOT", ctx.tmp_dir)

    on_exit(fn ->
      if previous,
        do: System.put_env("SYNAPSIS_WORKSPACE_ROOT", previous),
        else: System.delete_env("SYNAPSIS_WORKSPACE_ROOT")
    end)

    :ok
  end

  for {source, kind} <- [
        {:heartbeat, "heartbeat"},
        {:routine, "schedule"},
        {:routine, "heartbeat"}
      ] do
    @source source
    @kind kind
    test "stored #{@source} #{@kind} records explicit source through default native execution",
         ctx do
      label = "#{@source}-#{@kind}"
      saved = native_fixture(ctx.tmp_dir, label, "producer complete")
      config = stored_routine(saved, @kind, "0 0 1 1 *", @source)
      scheduler = scheduler()
      assert {:ok, queued} = LocalScheduler.trigger(scheduler, config["id"])
      completed = assert_native_run(queued, saved, ctx.tmp_dir, label)

      assert completed.metadata["automation_ref"] == %{
               "source" => Atom.to_string(@source),
               "id" => config["id"]
             }

      assert_scheduler_terminal(scheduler, config, completed, @source)

      assert {:ok, page} =
               Synapsis.RoutineRuns.page(saved.name, Atom.to_string(@source), config["id"])

      assert [%{id: id, status: "completed"}] = page.runs
      assert id == completed.id

      if @source == :routine and @kind == "schedule",
        do: assert_native_history_replay(saved, config, completed, ctx.tmp_dir)
    end
  end

  test "saved heartbeat Definition retains its source through Runner and idempotent occurrence",
       ctx do
    alias Synapsis.Agent.Routine.{Definition, Occurrence, Runner, State}
    saved = native_fixture(ctx.tmp_dir, "runner", "producer complete")

    assert {:ok, config} =
             Synapsis.Heartbeats.create(%{
               name: "history-runner-#{Ecto.UUID.generate()}",
               agent_name: saved.name,
               enabled: true,
               prompt: "Perform the occurrence effect",
               tool_profile: "native_agent",
               keep_history: true,
               schedule: "0 0 1 1 *",
               max_runtime_ms: 15_000
             })

    on_exit(fn -> Synapsis.Heartbeats.delete(config) end)

    assert {:ok, definition} =
             Definition.from_heartbeat(Map.from_struct(Synapsis.Heartbeats.get(config.id)))

    assert definition.tool_profile == "native_agent"
    occurrence = Occurrence.build(definition.id, DateTime.utc_now())
    assert {:ok, occurrence} = Occurrence.create_if_absent(occurrence)

    on_exit(fn ->
      Synapsis.DataCase.clear_coord("coord/routine_occurrences/#{definition.id}/")
      Synapsis.DataCase.clear_coord("coord/routines/#{definition.id}/")
    end)

    assert :ok = Runner.execute(definition, occurrence, await_ms: 15_000)
    terminal = Occurrence.get(definition.id, occurrence.occurrence_key)
    assert terminal.status == "completed"
    assert terminal.outcome == "completed"
    assert terminal.finished_at
    run = assert_native_run(Runs.get(terminal.run_id), saved, ctx.tmp_dir, "runner")
    assert run.kind == "heartbeat"
    assert run.heartbeat_id == definition.id
    assert run.routine_id == definition.id
    assert run.idempotency_key == occurrence.occurrence_key
    assert run.metadata["occurrence_key"] == occurrence.occurrence_key
    assert run.metadata["automation_ref"] == %{"source" => "heartbeat", "id" => definition.id}
    assert State.get_or_new(definition.id).last_run_id == run.id
    assert {:ok, ^terminal} = Occurrence.create_if_absent(occurrence)
    assert [^run] = Enum.filter(Runs.list_recent(limit: 100), &(&1.routine_id == definition.id))
    assert File.read!(Path.join(ctx.tmp_dir, "runner.txt")) == "effect"
  end

  test "daemon restart recovery preserves attributed metadata and interrupted history" do
    assert {:ok, _} = wait_for_ready()
    name = "recovery-history-#{Ecto.UUID.generate()}"

    assert {:ok, agent} =
             ConfigStore.put(:agent, %{
               "id" => Ecto.UUID.generate(),
               "name" => name,
               "enabled" => true
             })

    on_exit(fn -> ConfigStore.delete(:agent, agent["id"]) end)
    config = stored_routine(%{name: name}, "schedule", "0 0 1 1 *", :routine)

    metadata = %{
      "automation_ref" => %{"source" => "routine", "id" => config["id"]},
      "routine_name" => config["name"],
      "request_id" => "recovery-history-fixture"
    }

    assert {:ok, queued} =
             Runs.create(%{
               kind: "schedule",
               source: "scheduler",
               assistant_name: name,
               routine_id: config["id"],
               prompt: "Persist the recovery observation",
               tool_profile: "assistant_basic",
               metadata: metadata
             })

    assert {:ok, running} = Runs.mark_running(queued)
    assert {:ok, ^running} = Runs.fetch(running.id)
    supervisor = start_supervised!({Task.Supervisor, []})

    assert {:ok, [], 0, []} =
             Synapsis.Agent.Daemon.Recovery.run(
               %{runs: Runs, run_events: Synapsis.Agent.RunEvents},
               1,
               supervisor,
               1_000
             )

    assert {:ok, interrupted} = Runs.fetch(running.id)
    assert interrupted.status == "interrupted"
    assert interrupted.finished_at
    assert interrupted.error == "daemon_restarted"
    assert interrupted.metadata == Map.put(metadata, "interruption_reason", "daemon_restarted")
    assert {:ok, ^interrupted} = Synapsis.AgentRun.Store.fetch(running.id)
    assert {:ok, page} = Synapsis.RoutineRuns.page(name, "routine", config["id"])
    assert [%{id: id, status: "interrupted", automation_ref: ref}] = page.runs
    assert id == interrupted.id
    assert ref == metadata["automation_ref"]
    assert page.coverage == %{source_attribution: "explicit_only", legacy_history: "unknown"}
    assert Task.Supervisor.children(supervisor) == []
  end

  defp stored_routine(saved, kind, schedule, source) do
    assert {:ok, config} =
             ConfigStore.put(source, %{
               "id" => Ecto.UUID.generate(),
               "name" => "native-#{kind}-#{Ecto.UUID.generate()}",
               "kind" => kind,
               "enabled" => true,
               "schedule" => schedule,
               "agent_name" => saved.name,
               "tool_profile" => "native_agent",
               "prompt" => "Perform the native effect",
               "max_runtime_ms" => 15_000
             })

    on_exit(fn ->
      ConfigStore.delete(source, config["id"])
      LocalScheduler.reload()
    end)

    assert {:ok, ^config} = ConfigStore.get(source, config["id"])
    config
  end

  defp scheduler do
    assert :ok = LocalScheduler.reload()
    LocalScheduler
  end

  defp assert_scheduler_terminal(scheduler, config, run, source) do
    assert run.kind == config["kind"]
    assert run.routine_id == config["id"]

    assert {:ok, persisted} =
             wait_for(fn ->
               case ConfigStore.get(source, config["id"]) do
                 {:ok, %{"last_status" => "completed", "last_run_at" => at} = config}
                 when is_binary(at) ->
                   {:ok, config}

                 _ ->
                   :retry
               end
             end)

    assert persisted["tool_profile"] == "native_agent"
    assert persisted["agent_name"] == run.assistant_name
    assert is_binary(persisted["next_run_at"])

    assert [%{last_status: "completed"}] =
             Enum.filter(LocalScheduler.status(scheduler), &(&1.id == config["id"]))

    assert {:ok, _} =
             wait_for_status(Daemon, fn status ->
               status.active_count == 0 and status.queued_count == 0
             end)
  end

  defp assert_native_history_replay(saved, config, terminal, root) do
    alias Synapsis.Agent.TestSupport.SessionHarness
    alias Synapsis.Session.{DynamicSupervisor, Worker}
    owner = self()
    fixture = Gaoxy.Test.open()
    counter = start_supervised!({Agent, fn -> 0 end})

    assert :ok =
             Synapsis.Provider.Registry.register(saved.provider, %{
               type: "openai",
               api_key: "test-key",
               base_url: String.trim_trailing(Gaoxy.Test.url(fixture), "/")
             })

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(saved, %{
               tools: ["exec_command", "synapsis::automations"]
             })

    Gaoxy.Test.stub(fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      index = Agent.get_and_update(counter, &{&1, &1 + 1})
      send(owner, {:history_request, index, request, self()})

      if index in [0, 2] do
        receive do
          :continue_history -> :ok
        after
          5_000 -> raise "history fixture handshake timed out"
        end
      end

      chunks =
        case index do
          0 ->
            [
              Provider.tool_call_chunk("exec_command", "history-effect", %{
                "cmd" => "printf once >> history-effect.txt",
                "login" => false,
                "yield_time_ms" => 1000
              }),
              Provider.finish_chunk("tool_calls")
            ]

          1 ->
            [
              Provider.tool_call_chunk(
                Synapsis.Provider.ToolName.encode("synapsis::automations"),
                "history-query",
                %{"action" => "runs", "source" => "routine", "id" => config["id"]}
              ),
              Provider.finish_chunk("tool_calls")
            ]

          _ ->
            [Provider.text_chunk("history complete"), Provider.finish_chunk("stop")]
        end

      Provider.send_sse(conn, chunks)
    end)

    assert {:ok, session} =
             Synapsis.Sessions.create(saved.name, %{
               agent: saved.name,
               config: %{
                 "workspace_path" => root,
                 "subagents" => false,
                 "memory_context" => false
               }
             })

    on_exit(fn -> Synapsis.Sessions.delete(session.id) end)
    SessionHarness.subscribe!(session.id)
    assert :ok = Worker.send_message(session.id, "Read completed automation history")
    assert_receive {:history_request, 0, first, handler}, 5000
    [{active_worker, _}] = Registry.lookup(Synapsis.Session.Registry, session.id)
    {_, active_data} = :sys.get_state(active_worker)
    runtime = :sys.get_state(active_data.runtime_pid)
    catalog = :sys.get_state(runtime.root).catalog

    assert Enum.sort(Map.keys(catalog.registry.tools)) == [
             "exec_command",
             "synapsis::automations"
           ]

    assert catalog.registry.tools["synapsis::automations"].tool_revision == 2
    assert catalog.registry.tools["exec_command"].tool_revision == 1

    assert Enum.sort(Enum.map(first["tools"], & &1["function"]["name"])) ==
             Enum.sort(
               Enum.map(
                 ["exec_command", "synapsis::automations"],
                 &Synapsis.Provider.ToolName.encode/1
               )
             )

    send(handler, :continue_history)
    [{old_worker, _}] = Registry.lookup(Synapsis.Session.Registry, session.id)
    assert_receive {:history_request, 1, _, _}, 5000
    assert_receive {:history_request, 2, following, handler}, 5000
    live = Backplane.AgentRuntime.Conversation.status(runtime.root)
    assert live.phase == :running
    assert live.catalog_revision == 1
    assert {:ok, live_messages} = Synapsis.Agent.Runtime.ProviderMessages.to_host(live.messages)

    assert [%ToolResult{is_error: false}] =
             for(
               message <- live_messages,
               %ToolResult{tool_use_id: "history-query"} = part <- message.parts,
               do: part
             )

    root_monitor = Process.monitor(runtime.root)
    send(handler, :continue_history)
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000

    parts =
      for message <- Synapsis.Sessions.get_messages(session.id),
          %ToolResult{} = part <- message.parts,
          do: part

    assert [%ToolResult{is_error: false}, %ToolResult{is_error: false} = result] = parts
    page = result.projection["result"]["structured"]
    assert [%{"id" => id, "status" => "completed"}] = page["runs"]
    assert id == terminal.id
    assert hd(page["runs"])["automation_ref"] == %{"source" => "routine", "id" => config["id"]}

    assert page["coverage"] == %{
             "source_attribution" => "explicit_only",
             "legacy_history" => "unknown"
           }

    assert byte_size(Jason.encode!(result.projection["result"])) <= 65_536
    assert_wire_history(following, parts)
    assert_receive {:DOWN, ^root_monitor, :process, root_pid, _}, 5000
    assert root_pid == runtime.root
    assert {:ok, aggregate} = Synapsis.Runtime.Store.load(runtime.store.namespace, runtime.run_id)

    assert aggregate.run.state == :completed

    operations =
      for {_, intent} <- aggregate.run.execution_intents,
          intent.type == :tool,
          do: intent.operation

    assert [%{tool_revision: 2, catalog_revision: 1}] =
             Enum.filter(operations, &(&1.tool_name == "synapsis::automations"))

    assert Enum.sort(Enum.map(operations, & &1.tool_name)) == [
             "exec_command",
             "synapsis::automations"
           ]

    assert {:ok, turns} = Store.list_turns(session.id)

    assert Enum.count(
             for(turn <- turns, part <- turn.parts, part[:type] == "tool_result", do: part)
           ) == 2

    for part <- parts do
      assert Enum.any?(
               for(turn <- turns, stored <- turn.parts, do: stored),
               &(&1[:projection] == part.projection and &1[:content] == part.content)
             )
    end

    monitor = Process.monitor(old_worker)
    assert :ok = DynamicSupervisor.stop_session(session.id)
    assert_receive {:DOWN, ^monitor, :process, ^old_worker, _}, 5000
    SessionHarness.ensure_running!(session.id)
    [{new_worker, _}] = Registry.lookup(Synapsis.Session.Registry, session.id)
    assert new_worker != old_worker
    assert :ok = Worker.send_message(session.id, "Recall completed history")
    assert_receive {:history_request, 3, replay, _}, 5000
    assert_wire_history(replay, parts)
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000

    assert for(
             message <- Synapsis.Sessions.get_messages(session.id),
             %ToolResult{} = part <- message.parts,
             do: part
           ) == parts

    assert File.read!(Path.join(root, "history-effect.txt")) == "once"
    assert File.read!(Path.join(root, "routine-schedule.txt")) == "effect"
    assert Agent.get(counter, & &1) == 4
    assert {:ok, ^terminal} = Runs.fetch(terminal.id)
    assert :ok = DynamicSupervisor.stop_session(session.id)
  end

  defp assert_wire_history(request, parts) do
    for part <- parts do
      assert %{"role" => "tool", "tool_call_id" => part.tool_use_id, "content" => part.content} in request[
               "messages"
             ]
    end
  end

  defp native_fixture(root, label, response) do
    fixture = Gaoxy.Test.open()
    provider = "native-producer-#{Ecto.UUID.generate()}"
    owner = self()

    assert :ok =
             Synapsis.Provider.Registry.register(provider, %{
               type: "openai",
               api_key: "test-key",
               base_url: String.trim_trailing(Gaoxy.Test.url(fixture), "/")
             })

    assert {:ok, saved} =
             Synapsis.AgentConfigs.create(%{
               name: provider,
               provider: provider,
               model: "producer-model",
               tools: ["exec_command"],
               tool_contract_version: 1,
               config: %{"workspace_path" => root}
             })

    Gaoxy.Test.stub(fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      following? = Enum.any?(request["messages"], &(&1["role"] == "tool"))
      send(owner, {:producer_request, label, following?, request})

      chunks =
        if following? do
          [Provider.text_chunk(response), Provider.finish_chunk("stop")]
        else
          [
            Provider.tool_call_chunk("exec_command", "producer-call", %{
              "cmd" => "printf effect >> #{label}.txt",
              "login" => false,
              "yield_time_ms" => 1000
            }),
            Provider.finish_chunk("tool_calls")
          ]
        end

      Provider.send_sse(conn, chunks)
    end)

    on_exit(fn ->
      for run <- Runs.list_recent(limit: 100),
          run.assistant_name == saved.name,
          is_binary(run.session_id),
          do: Synapsis.Sessions.delete(run.session_id)

      Synapsis.AgentConfigs.delete(saved)
      Synapsis.Provider.Registry.unregister(provider)
    end)

    saved
  end

  defp assert_native_run(run, saved, root, label) do
    assert run.tool_profile == "native_agent"
    assert run.assistant_name == saved.name
    assert run.capability_snapshot["agent_id"] == saved.id
    assert run.capability_snapshot["agent_name"] == saved.name
    assert run.capability_snapshot["tool_names"] == ["exec_command"]
    assert {:ok, completed} = wait_for_run(run.id, "completed")
    assert completed.capability_snapshot == run.capability_snapshot
    assert completed.finished_at
    assert_receive {:producer_request, ^label, false, first}, 5_000
    assert Enum.map(first["tools"], & &1["function"]["name"]) == ["exec_command"]
    assert_receive {:producer_request, ^label, true, following}, 5_000
    assert File.read!(Path.join(root, "#{label}.txt")) == "effect"

    assert [%ToolResult{is_error: false} = result] =
             for(
               message <- Synapsis.Sessions.get_messages(completed.session_id),
               %ToolResult{} = part <- message.parts,
               do: part
             )

    assert %{"role" => "tool", "tool_call_id" => result.tool_use_id, "content" => result.content} in following[
             "messages"
           ]

    assert {:ok, turns} = Store.list_turns(completed.session_id)

    assert Enum.any?(
             for(turn <- turns, part <- turn.parts, do: part),
             &(&1[:type] == "tool_result" and &1[:content] == result.content)
           )

    assert {:ok, durable} = Runs.fetch(completed.id)
    assert durable == completed
    completed
  end
end
