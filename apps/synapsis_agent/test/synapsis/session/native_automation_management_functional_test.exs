defmodule Synapsis.Session.NativeAutomationManagementFunctionalTest do
  use ExUnit.Case, async: false

  import Synapsis.Agent.DaemonCase,
    only: [wait_for: 1, wait_for_ready: 0, wait_for_run: 2]

  alias Synapsis.Agent.{Daemon, Runs}
  alias Synapsis.Agent.Heartbeat.LocalScheduler
  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Config.Store, as: ConfigStore
  alias Synapsis.Part.ToolResult
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir
  @tool "synapsis::automations_manage"

  setup %{tmp_dir: root} do
    assert {:ok, _} = wait_for_ready()

    original =
      for type <- [:agent, :routine, :heartbeat] do
        [{pid, _}] = Registry.lookup(Synapsis.Config.Store.Registry, type)
        {type, :sys.get_state(pid).load_error, :ets.tab2list(:"synapsis_config_#{type}")}
      end

    previous = System.get_env("SYNAPSIS_CONFIG_DIR")
    directory = Path.join(root, "config")
    File.mkdir_p!(directory)
    System.put_env("SYNAPSIS_CONFIG_DIR", directory)

    for type <- [:agent, :routine, :heartbeat] do
      File.write!(ConfigStore.file_path(type), "")
      assert :ok = ConfigStore.reload(type)
    end

    assert :ok = LocalScheduler.reload()

    on_exit(fn ->
      if previous,
        do: System.put_env("SYNAPSIS_CONFIG_DIR", previous),
        else: System.delete_env("SYNAPSIS_CONFIG_DIR")

      for {type, load_error, entries} <- original do
        table = :"synapsis_config_#{type}"
        :ets.delete_all_objects(table)
        :ets.insert(table, entries)
        [{pid, _}] = Registry.lookup(Synapsis.Config.Store.Registry, type)
        :sys.replace_state(pid, &Map.put(&1, :load_error, load_error))
      end

      LocalScheduler.reload()
    end)

    :ok
  end

  test "explicit native run selection forces disabled same-UUID sources and replays durable results",
       ctx do
    fixture = fixture(ctx.tmp_dir)
    id = Ecto.UUID.generate()
    target = future(60_000)
    routine = config(fixture, :routine, id, at(target), %{"enabled" => false})
    heartbeat = config(fixture, :heartbeat, id, "0 0 1 1 *", %{"enabled" => false})
    plan(fixture, [args("routine", id, "force"), args("heartbeat", id, "force")])
    session = management_session(fixture)
    assert :ok = Worker.send_message(session.id, "Request management effects")
    assert_receive {:management_request, 2, following}, 10_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    parts = results(session.id)
    assert length(parts) == 2

    runs =
      for {source, part} <- Enum.zip(~w(routine heartbeat), parts) do
        assert part.is_error == false
        result = structured(part)
        assert result["enqueued"] == true
        assert result["finished"] == true
        assert result["source"] == source
        assert result["id"] == id
        assert result["run"]["status"] == "completed"
        assert {:ok, run} = Runs.fetch(result["run"]["id"])
        assert run.status == "completed"
        assert result["run"]["started_at"] == DateTime.to_iso8601(run.started_at)
        assert result["run"]["finished_at"] == DateTime.to_iso8601(run.finished_at)
        assert run.metadata["automation_ref"] == %{"source" => source, "id" => id}
        assert run.tool_profile == "native_agent"
        assert run.capability_snapshot["agent_id"] == fixture.agent.id

        assert Enum.sort(run.capability_snapshot["tool_names"]) ==
                 Enum.sort([@tool, "exec_command"])

        assert {:ok, ^run} = Synapsis.AgentRun.Store.fetch(run.id)
        assert_effect(fixture, source, "effect")
        run
      end

    assert hd(runs).id != List.last(runs).id
    assert {:ok, current} = ConfigStore.get(:routine, id)
    assert current["schedule"] == routine["schedule"]
    assert current["schedule_generation"] == routine["schedule_generation"]
    assert current["enabled"] == false
    assert current["next_run_at"] == DateTime.to_iso8601(target)
    assert {:ok, current_heartbeat} = ConfigStore.get(:heartbeat, id)
    assert current_heartbeat["enabled"] == heartbeat["enabled"]
    assert_wire(following, parts)
    assert_persisted(session.id, parts)
    replay(session.id, parts, 3)
    assert_effect(fixture, "routine", "effect")
    assert_effect(fixture, "heartbeat", "effect")
    assert length(own_runs(fixture)) == 2
  end

  test "omitted runMode is due, force preserves future one-shot and its actual timer still fires",
       ctx do
    fixture = fixture(ctx.tmp_dir)
    id = Ecto.UUID.generate()
    target = future(5_000)
    routine = config(fixture, :routine, id, at(target))

    plan(fixture, [
      Map.delete(args("routine", id, "due"), "runMode"),
      args("routine", id, "force")
    ])

    session = management_session(fixture)
    assert :ok = Worker.send_message(session.id, "Request due then force")
    assert_receive {:management_request, 2, following}, 10_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    [noop, forced] = results(session.id)
    assert noop.is_error == false
    assert structured(noop)["enqueued"] == false
    assert structured(noop)["reason"] == "not_due"
    assert structured(noop)["run"] == nil
    assert forced.is_error == false
    forced_id = structured(forced)["run"]["id"]
    assert {:ok, forced_run} = Runs.fetch(forced_id)
    assert forced_run.metadata["routine_schedule"]["advance"] == false
    assert forced_run.idempotency_key =~ ":manual:"
    assert {:ok, persisted} = ConfigStore.get(:routine, id)
    assert persisted["schedule_generation"] == routine["schedule_generation"]
    assert persisted["next_run_at"] == DateTime.to_iso8601(target)
    assert :sys.get_state(LocalScheduler).timers[{"routine", id}].next_run_at == target

    assert {:ok, scheduled} =
             wait_for(fn ->
               case Enum.find(
                      own_runs(fixture),
                      &(&1.id != forced_id and &1.status == "completed")
                    ) do
                 nil -> :retry
                 run -> {:ok, run}
               end
             end)

    assert scheduled.metadata["routine_schedule"]["advance"] == true
    assert DateTime.compare(scheduled.started_at, target) in [:eq, :gt]
    assert DateTime.compare(scheduled.scheduled_for, target) == :eq
    assert length(own_runs(fixture)) == 2
    assert_effect(fixture, "routine", "effecteffect")
    assert_wire(following, [noop, forced])
    assert_persisted(session.id, [noop, forced])

    assert {:ok, :deleted} =
             wait_for(fn ->
               if ConfigStore.get(:routine, id) == {:error, :not_found},
                 do: {:ok, :deleted},
                 else: :retry
             end)
  end

  test "model due request observes the actual timer's single durable occurrence", ctx do
    fixture = fixture(ctx.tmp_dir, hold_effect: true)
    id = Ecto.UUID.generate()
    target = future(500)
    config(fixture, :routine, id, at(target), %{"deleteAfterRun" => false})
    assert_receive {:effect_waiting, handler}, 5_000
    assert [timer_run] = own_runs(fixture)
    plan(fixture, [Map.delete(args("routine", id, "due"), "runMode")])
    session = management_session(fixture)
    assert :ok = Worker.send_message(session.id, "Request current due occurrence")
    assert_receive {:management_request, 0, _}, 5_000
    assert {:ok, %{running: true}} = LocalScheduler.public_status()
    send(handler, :continue_effect)
    assert_receive {:management_request, 1, following}, 10_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert [part] = results(session.id)
    assert part.is_error == false
    assert structured(part)["run"]["id"] == timer_run.id
    assert structured(part)["finished"] == true
    assert {:ok, completed} = wait_for_run(timer_run.id, "completed")
    assert completed.metadata["routine_schedule"]["advance"] == true
    assert DateTime.compare(completed.scheduled_for, target) == :eq
    assert [^completed] = own_runs(fixture)
    assert {:ok, ^completed} = Runs.fetch_by_idempotency_key(completed.idempotency_key)
    assert_effect(fixture, "routine", "effect")
    assert_wire(following, [part])
    assert_persisted(session.id, [part])
  end

  test "a daemon-owned requester acknowledges its queued run before its own turn finishes", ctx do
    fixture = fixture(ctx.tmp_dir)
    id = Ecto.UUID.generate()
    config(fixture, :routine, id, at(future(60_000)), %{"enabled" => false})
    plan(fixture, [Map.delete(args("routine", id, "force"), "timeoutMs")])

    assert {:ok, requester} =
             Daemon.trigger(:schedule, %{
               routine_id: Ecto.UUID.generate(),
               assistant_name: fixture.agent.name,
               prompt: "Request queued management effect",
               tool_profile: "native_agent",
               no_overlap: true,
               max_runtime_ms: 15_000
             })

    assert_receive {:management_request, 1, following}, 5_000
    assert {:ok, requester} = wait_for_run(requester.id, "completed")
    assert [part] = results(requester.session_id)
    assert part.is_error == false
    result = structured(part)
    assert result["enqueued"] == true
    assert result["finished"] == false
    assert result["run"]["status"] == "queued"
    assert is_binary(result["note"])
    assert {:ok, child} = wait_for_run(result["run"]["id"], "completed")
    assert child.id != requester.id
    assert child.metadata["automation_ref"] == %{"source" => "routine", "id" => id}
    assert_effect(fixture, "routine", "effect")
    assert_wire(following, [part])
    assert_persisted(requester.session_id, [part])
  end

  test "short terminal observation acknowledges a real run before its held provider completes",
       ctx do
    fixture = fixture(ctx.tmp_dir, hold_effect: true)
    id = Ecto.UUID.generate()
    config(fixture, :routine, id, at(future(60_000)), %{"enabled" => false})
    plan(fixture, [Map.put(args("routine", id, "force"), "timeoutMs", 1)])
    session = management_session(fixture)
    assert :ok = Worker.send_message(session.id, "Request short terminal observation")
    assert_receive {:management_request, 1, following}, 5_000

    acknowledgement =
      following["messages"]
      |> Enum.find(&(&1["role"] == "tool" and &1["tool_call_id"] == "manage-0"))
      |> Map.fetch!("content")
      |> Jason.decode!()

    assert acknowledgement["enqueued"] == true
    assert acknowledgement["finished"] == false
    run_id = acknowledgement["run"]["id"]
    assert {:ok, acknowledged} = Runs.fetch(run_id)
    assert acknowledged.metadata["automation_ref"] == %{"source" => "routine", "id" => id}
    assert_receive {:effect_waiting, handler}, 5_000
    send(handler, :continue_effect)

    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert [part] = results(session.id)
    assert part.is_error == false
    assert structured(part) == acknowledgement
    assert {:ok, completed} = wait_for_run(run_id, "completed")
    assert completed.id == acknowledged.id
    assert [^completed] = own_runs(fixture)
    assert_effect(fixture, "routine", "effect")
    assert_wire(following, [part])
    assert_persisted(session.id, [part])
  end

  defp fixture(root, opts \\ []) do
    owner = self()
    http = Gaoxy.Test.open()
    name = "automation-management-#{Ecto.UUID.generate()}"
    state = start_supervised!({Agent, fn -> %{plan: [], management: 0} end})

    assert :ok =
             Synapsis.Provider.Registry.register(name, %{
               type: "openai",
               api_key: "test-key",
               base_url: String.trim_trailing(Gaoxy.Test.url(http), "/")
             })

    assert {:ok, agent} =
             Synapsis.AgentConfigs.create(%{
               name: name,
               provider: name,
               model: "automation-management-model",
               tools: [@tool, "exec_command"],
               tool_contract_version: 1,
               config: %{"workspace_path" => root}
             })

    Gaoxy.Test.stub(http, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      encoded = Jason.encode!(request["messages"])

      source =
        Enum.find(~w(routine heartbeat), &String.contains?(encoded, "automation-execute:#{&1}"))

      chunks =
        if source do
          following? = Enum.any?(request["messages"], &(&1["role"] == "tool"))

          if not following? and Keyword.get(opts, :hold_effect, false) do
            send(owner, {:effect_waiting, self()})

            receive do
              :continue_effect -> :ok
            after
              10_000 -> raise "native automation effect handshake timed out"
            end
          end

          if following? do
            [
              DeterministicProvider.text_chunk("automation complete"),
              DeterministicProvider.finish_chunk("stop")
            ]
          else
            [
              DeterministicProvider.tool_call_chunk("exec_command", "effect-#{source}", %{
                "cmd" => "printf effect >> management-#{source}.txt",
                "login" => false,
                "yield_time_ms" => 1_000
              }),
              DeterministicProvider.finish_chunk("tool_calls")
            ]
          end
        else
          {index, commands} =
            Agent.get_and_update(state, fn value ->
              {{value.management, value.plan}, %{value | management: value.management + 1}}
            end)

          send(owner, {:management_request, index, request})

          case Enum.at(commands, index) do
            nil ->
              [
                DeterministicProvider.text_chunk("management complete"),
                DeterministicProvider.finish_chunk("stop")
              ]

            arguments ->
              [
                DeterministicProvider.tool_call_chunk(
                  Synapsis.Provider.ToolName.encode(@tool),
                  "manage-#{index}",
                  arguments
                ),
                DeterministicProvider.finish_chunk("tool_calls")
              ]
          end
        end

      DeterministicProvider.send_sse(conn, chunks)
    end)

    on_exit(fn ->
      for run <- Runs.list_recent(limit: 1_000),
          run.assistant_name == agent.name,
          is_binary(run.session_id),
          do: Synapsis.Sessions.delete(run.session_id)

      Synapsis.AgentConfigs.delete(agent)
      Synapsis.Provider.Registry.unregister(name)
    end)

    %{agent: agent, state: state, root: root}
  end

  defp config(fixture, type, id, schedule, extra \\ %{}) do
    assert {:ok, config} =
             ConfigStore.put(
               type,
               Map.merge(
                 %{
                   "id" => id,
                   "name" => "management-#{type}-#{id}",
                   "kind" => if(type == :routine, do: "schedule", else: "heartbeat"),
                   "enabled" => true,
                   "schedule" => schedule,
                   "agent_name" => fixture.agent.name,
                   "tool_profile" => "native_agent",
                   "prompt" => "automation-execute:#{type}",
                   "max_runtime_ms" => 15_000
                 },
                 extra
               )
             )

    on_exit(fn ->
      ConfigStore.delete(type, id)
      LocalScheduler.reload()
    end)

    assert :ok = LocalScheduler.reload()
    config
  end

  defp plan(fixture, commands), do: Agent.update(fixture.state, &%{&1 | plan: commands})

  defp args(source, id, mode),
    do: %{
      "action" => "run",
      "source" => source,
      "id" => id,
      "runMode" => mode,
      "timeoutMs" => 5_000
    }

  defp management_session(fixture) do
    assert {:ok, session} =
             Synapsis.Sessions.create(fixture.agent.name, %{
               agent: fixture.agent.name,
               config: %{
                 "workspace_path" => fixture.root,
                 "subagents" => false,
                 "memory_context" => false
               }
             })

    on_exit(fn -> Synapsis.Sessions.delete(session.id) end)
    SessionHarness.subscribe!(session.id)
    session
  end

  defp results(session_id),
    do:
      for(
        message <- Synapsis.Sessions.get_messages(session_id),
        %ToolResult{} = part <- message.parts,
        do: part
      )

  defp structured(part), do: part.projection["result"]["structured"]

  defp assert_wire(request, parts) do
    for part <- parts do
      assert %{"role" => "tool", "tool_call_id" => part.tool_use_id, "content" => part.content} in request[
               "messages"
             ]
    end
  end

  defp assert_persisted(session_id, parts) do
    assert {:ok, turns} = Store.list_turns(session_id)

    for part <- parts do
      assert Enum.any?(
               for(turn <- turns, stored <- turn.parts, do: stored),
               &(&1[:type] == "tool_result" and &1[:content] == part.content and
                   &1[:projection] == part.projection)
             )
    end
  end

  defp replay(session_id, parts, request_index) do
    SessionHarness.ensure_running!(session_id)
    [{old, _}] = Registry.lookup(Synapsis.Session.Registry, session_id)
    monitor = Process.monitor(old)
    assert :ok = DynamicSupervisor.stop_session(session_id)
    assert_receive {:DOWN, ^monitor, :process, ^old, _}, 5_000
    SessionHarness.ensure_running!(session_id)
    [{replacement, _}] = Registry.lookup(Synapsis.Session.Registry, session_id)
    assert replacement != old
    assert :ok = Worker.send_message(session_id, "Recall management result")
    assert_receive {:management_request, ^request_index, request}, 5_000
    assert_wire(request, parts)
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert results(session_id) == parts
    assert :ok = DynamicSupervisor.stop_session(session_id)
  end

  defp own_runs(fixture),
    do: Runs.list_recent(limit: 1_000) |> Enum.filter(&(&1.assistant_name == fixture.agent.name))

  defp assert_effect(fixture, source, expected),
    do: assert(File.read!(Path.join(fixture.root, "management-#{source}.txt")) == expected)

  defp future(ms),
    do: DateTime.utc_now() |> DateTime.add(ms, :millisecond) |> DateTime.truncate(:millisecond)

  defp at(target), do: %{"kind" => "at", "at" => DateTime.to_iso8601(target)}
end
