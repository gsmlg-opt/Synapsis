defmodule Synapsis.Session.NativeAutomationWebhookFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  import Synapsis.Agent.DaemonCase, only: [wait_for: 1, wait_for_ready: 0, wait_for_run: 2]

  alias Synapsis.Agent.{Daemon, Routines, Runs}
  alias Synapsis.Agent.Heartbeat.LocalScheduler
  alias Synapsis.Agent.TestSupport.DeterministicProvider, as: Provider
  alias Synapsis.Config.Store, as: ConfigStore
  alias Synapsis.Part.{Text, ToolResult}
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}
  alias Synapsis.Sessions

  @moduletag :tmp_dir
  @create "synapsis::automations_create"
  @update "synapsis::automations_update"
  @history "synapsis::automations"
  @prompt "\n  Authored webhook prompt\nkeep exact bytes  "
  @summary "Webhook completed\n原文 and exact trailing bytes  "
  @older "Earlier assistant text before the final empty response"

  setup %{tmp_dir: root} do
    assert {:ok, _} = wait_for_ready()
    previous = System.get_env("SYNAPSIS_CONFIG_DIR")

    snapshots =
      for type <- [:agent, :routine, :heartbeat] do
        [{pid, _}] = Registry.lookup(Synapsis.Config.Store.Registry, type)
        {type, pid, :sys.get_state(pid).load_error, :ets.tab2list(:"synapsis_config_#{type}")}
      end

    directory = Path.join(root, "config")
    File.mkdir_p!(directory)
    System.put_env("SYNAPSIS_CONFIG_DIR", directory)

    for {type, _, _, _} <- snapshots do
      File.write!(ConfigStore.file_path(type), "")
      assert :ok = ConfigStore.reload(type)
    end

    assert :ok = LocalScheduler.reload()
    assert :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "agent:daemon")

    on_exit(fn ->
      if previous,
        do: System.put_env("SYNAPSIS_CONFIG_DIR", previous),
        else: System.delete_env("SYNAPSIS_CONFIG_DIR")

      for {type, pid, error, entries} <- snapshots do
        table = :"synapsis_config_#{type}"
        :ets.delete_all_objects(table)
        :ets.insert(table, entries)
        :sys.replace_state(pid, &Map.put(&1, :load_error, error))
      end

      LocalScheduler.reload()
      File.rm_rf!(root)
    end)

    :ok
  end

  test "native persisted edits freeze each admitted job and own primary HTTP through ACK, history and Worker replay",
       %{tmp_dir: root} do
    f = fixture(root)
    source = source(f)
    first_target = Gaoxy.Test.url(f.receiver, "/first")
    second_target = Gaoxy.Test.url(f.receiver, "/second")

    {created, creation_result} = invoke(source, f, @create, create_args(f, first_target))
    id = created["id"]
    assert created["persisted"] == true
    assert created["activation"] == "reloaded"
    assert created["delivery"] == %{"mode" => "webhook", "to" => first_target}
    assert {:ok, original} = ConfigStore.get(:routine, id)
    assert original["prompt"] == @prompt
    assert original["automation_origin"] == %{"agent_id" => f.agent.id, "session_id" => source.id}
    assert :ok = ConfigStore.reload(:routine)
    assert {:ok, ^original} = ConfigStore.get(:routine, id)
    assert File.read!(ConfigStore.file_path(:routine)) =~ first_target

    assert {:ok, admitted} = Routines.trigger({"routine", id})
    assert_receive {:automation_wire, false, first_request, model_handler}, 5_000
    assert user_texts(first_request) == [@prompt]
    assert {:ok, running} = wait_for_run(admitted.id, "running")
    assert running.metadata["automation_job"]["delivery"] == original["delivery"]

    {updated, update_result} =
      invoke(source, f, @update, %{
        "source" => "routine",
        "id" => id,
        "patch" => %{
          "name" => "Edited webhook job",
          "prompt" => "Later admitted prompt",
          "delivery" => %{"to" => second_target}
        }
      })

    assert updated["persisted"] == true
    assert updated["activation"] == "reloaded"
    assert updated["delivery"] == %{"mode" => "webhook", "to" => second_target}
    assert :ok = ConfigStore.reload(:routine)
    assert :ok = LocalScheduler.reload()
    assert {:ok, edited} = ConfigStore.get(:routine, id)
    assert edited["delivery"] == updated["delivery"]
    assert edited["automation_origin"] == original["automation_origin"]
    assert File.read!(ConfigStore.file_path(:routine)) =~ second_target

    send(model_handler, :continue_automation_execution)
    assert_receive {:webhook_received, "/first", first_body, receiver_handler}, 5_000
    assert_payload(first_body, original, admitted, @summary)
    child = assert_owned_delivery(admitted.id)
    monitor = Process.monitor(child)
    assert length(Gaoxy.Test.requests(f.receiver).entries) == 1
    send(receiver_handler, :acknowledge_webhook)
    assert {:ok, first} = wait_for_run(admitted.id, "completed")
    assert_receive {:DOWN, ^monitor, :process, ^child, _}, 5_000
    assert_delivered(first, first_target)
    assert_completion_event(first)
    assert {:ok, ^first} = Synapsis.AgentRun.Store.fetch(first.id)
    assert first.session_id != source.id
    assert first.metadata["automation_job"]["prompt"] == @prompt
    assert first.metadata["automation_job"]["name"] == original["name"]

    assert {:ok, :released} =
             wait_for(fn ->
               if Daemon.status().active_run_id == nil, do: {:ok, :released}, else: :retry
             end)

    assert {:ok, later} = Routines.trigger({"routine", id})
    assert_receive {:automation_wire, false, next_request, next_model_handler}, 5_000
    assert user_texts(next_request) == [edited["prompt"]]
    send(next_model_handler, :continue_automation_execution)
    assert_receive {:webhook_received, "/second", second_body, next_receiver_handler}, 5_000
    assert_payload(second_body, edited, later, @summary)
    next_child = assert_owned_delivery(later.id)
    next_monitor = Process.monitor(next_child)
    send(next_receiver_handler, :acknowledge_webhook)
    assert {:ok, second} = wait_for_run(later.id, "completed")
    assert_receive {:DOWN, ^next_monitor, :process, ^next_child, _}, 5_000
    assert_delivered(second, second_target)
    assert_completion_event(second)
    assert {:ok, saved} = ConfigStore.get(:routine, id)
    assert saved["deleteAfterRun"] == false

    history_source = source(%{f | agent: f.route})

    {history, history_result} =
      invoke(history_source, f, @history, %{"action" => "runs", "source" => "routine", "id" => id})

    assert Enum.sort(Enum.map(history["runs"], & &1["id"])) == Enum.sort([first.id, second.id])

    for entry <- history["runs"] do
      assert entry["status"] == "completed"
      assert entry["automation_completion_status"] == "succeeded"
      assert entry["automation_delivery"]["status"] == "delivered"
      assert entry["automation_delivery"]["http_status"] == 204
      assert entry["summary"] == @summary
    end

    parts = [creation_result, update_result]
    assert_persisted(source.id, parts)
    assert_replay(source.id, parts)
    assert_persisted(history_source.id, [history_result])
    assert_replay(history_source.id, [history_result])
    assert length(Gaoxy.Test.requests(f.receiver).entries) == 2
    assert length(automation_requests(f)) == 2
    assert Enum.all?(assistant_texts(source.id), &(&1 != @summary))
    assert_fixtures_verified(f)
  end

  test "a real at timer retains its one-shot config until primary ACK and disables it after succeeded completion",
       %{tmp_dir: root} do
    f = fixture(root)
    source = source(f)
    target = Gaoxy.Test.url(f.receiver, "/first")
    at = DateTime.utc_now() |> DateTime.add(2_000, :millisecond) |> DateTime.to_iso8601()
    args = create_args(f, target) |> Map.put("schedule", %{"kind" => "at", "at" => at})
    {created, _} = invoke(source, f, @create, args)
    id = created["id"]
    assert_receive {:automation_wire, false, _request, model_handler}, 5_000
    send(model_handler, :continue_automation_execution)
    assert_receive {:webhook_received, "/first", body, receiver_handler}, 5_000

    assert {:ok, run} =
             wait_for(fn ->
               case Enum.find(Runs.list_recent(limit: 100), &(&1.routine_id == id)) do
                 nil -> :retry
                 run -> {:ok, run}
               end
             end)

    assert {:ok, before_ack} = ConfigStore.get(:routine, id)
    assert before_ack["enabled"] == true
    assert before_ack["deleteAfterRun"] == false
    assert_payload(body, before_ack, run, @summary)
    child = assert_owned_delivery(run.id)
    monitor = Process.monitor(child)
    send(receiver_handler, :acknowledge_webhook)
    assert {:ok, completed} = wait_for_run(run.id, "completed")
    assert_receive {:DOWN, ^monitor, :process, ^child, _}, 5_000
    assert_delivered(completed, target)
    assert_completion_event(completed)

    assert {:ok, disabled} =
             wait_for(fn ->
               case ConfigStore.get(:routine, id) do
                 {:ok, %{"enabled" => false} = config} -> {:ok, config}
                 _ -> :retry
               end
             end)

    assert disabled["last_status"] == "completed"
    assert :ok = ConfigStore.reload(:routine)
    assert :ok = LocalScheduler.reload()
    assert {:ok, reloaded} = ConfigStore.get(:routine, id)
    assert reloaded["enabled"] == false
    assert :sys.get_state(LocalScheduler).timers[{"routine", id}] == nil
    assert Enum.filter(Runs.list_recent(limit: 100), &(&1.routine_id == id)) == [completed]
    assert length(Gaoxy.Test.requests(f.receiver).entries) == 1
    assert length(automation_requests(f)) == 1
    assert_fixtures_verified(f)
  end

  for {label, text} <- [{"empty", ""}, {"ECMAScript whitespace", "\uFEFF\u00A0\u2000\t\n"}] do
    @label label
    @text text
    test "a genuine final #{@label} response suppresses POST without selecting older assistant text",
         %{tmp_dir: root} do
      f = fixture(root, final_text: @text, older_assistant: true, hold_model: false)
      source = source(f)
      target = Gaoxy.Test.url(f.receiver, "/empty")
      {created, _} = invoke(source, f, @create, create_args(f, target))
      assert {:ok, admitted} = Routines.trigger({"routine", created["id"]})
      assert {:ok, completed} = wait_for_run(admitted.id, "completed")
      assert completed.summary == @text
      assert completed.metadata["automation_completion_status"] == "succeeded"

      assert Map.take(
               completed.metadata["automation_delivery"],
               ~w(mode status delivered attempted suppression_reason)
             ) == %{
               "mode" => "webhook",
               "status" => "not-delivered",
               "delivered" => false,
               "attempted" => false,
               "suppression_reason" => "empty"
             }

      assert @older in assistant_texts(completed.session_id)
      assert File.read!(Path.join(root, "webhook-empty-effect.txt")) == "effect"
      assert length(Gaoxy.Test.requests(f.receiver).entries) == 0
      assert length(automation_requests(f)) == 2
      assert_completion_event(completed)
      assert {:ok, ^completed} = Synapsis.AgentRun.Store.fetch(completed.id)
      assert_fixtures_verified(f)
    end
  end

  defp assert_owned_delivery(id) do
    assert {:ok, durable} = Synapsis.AgentRun.Store.fetch(id)
    assert durable.status == "running"
    assert durable.finished_at == nil
    state = :sys.get_state(Daemon)
    active = state.active_run
    assert active.run.id == id
    assert active.phase == :delivering
    assert is_pid(active.delivery_pid)
    assert Process.alive?(active.delivery_pid)
    assert active.delivery_pid in Task.Supervisor.children(state.task_supervisor)
    assert {:links, links} = Process.info(active.task_pid, :links)
    assert active.delivery_pid in links
    assert Enum.count(links, &(&1 == active.delivery_pid)) == 1
    active.delivery_pid
  end

  defp assert_payload(body, config, admitted, summary) do
    assert {:ok, running} = Runs.fetch(admitted.id)
    assert body["jobId"] == config["id"]
    assert body["action"] == "finished"
    assert body["status"] == "ok", "primary webhook core outcome: #{inspect(body)}"
    assert body["summary"] == summary
    assert body["delivered"] == true
    assert body["deliveryStatus"] == "delivered"
    assert body["sessionId"] == running.session_id
    assert is_integer(body["runAtMs"])
    assert body["runAtMs"] == DateTime.to_unix(running.started_at, :millisecond)
    assert is_integer(body["durationMs"]) and body["durationMs"] >= 0

    assert body["delivery"] == %{
             "intended" => %{"to" => config["delivery"]["to"], "source" => "explicit"},
             "resolved" => %{
               "to" => config["delivery"]["to"],
               "source" => "explicit",
               "ok" => true
             },
             "delivered" => true
           }

    expected =
      Map.take(config, ~w(id name prompt schedule timezone enabled agent_name
        automation_contract_version automation_origin session_target wake_mode delivery
        provider model deleteAfterRun max_runtime_ms no_overlap createdAtMs))
      |> Map.put("source", "routine")
      |> Map.put("state", %{"runningAtMs" => body["runAtMs"]})

    assert body["job"] == expected

    assert Map.keys(body) -- ~w(jobId action job runAtMs durationMs status summary delivered
             deliveryStatus delivery sessionId model provider usage diagnostics error sessionKey) ==
             []

    assert Map.take(body, ~w(error diagnostics usage sessionKey)) == %{}
  end

  defp assert_delivered(run, target) do
    assert run.summary == @summary
    assert run.metadata["automation_completion_status"] == "succeeded"

    assert Map.take(
             run.metadata["automation_delivery"],
             ~w(mode status delivered attempted http_status attempt_count intended resolved)
           ) == %{
             "mode" => "webhook",
             "status" => "delivered",
             "delivered" => true,
             "attempted" => true,
             "http_status" => 204,
             "attempt_count" => 1,
             "intended" => %{"to" => target, "source" => "explicit"},
             "resolved" => %{"to" => target, "source" => "explicit", "ok" => true}
           }
  end

  defp assert_completion_event(run) do
    id = run.id

    assert_receive {:agent_daemon_event,
                    %{event: "agent.run.completed", run_id: ^id, payload: payload}},
                   5_000

    assert payload.automation_completion_status == "succeeded"
    assert payload.automation_delivery == run.metadata["automation_delivery"]
    assert payload.automation_ref == run.metadata["automation_ref"]
  end

  defp create_args(f, target),
    do: %{
      "name" => "Original webhook job",
      "prompt" => @prompt,
      "provider" => f.provider,
      "model" => "automation-model",
      "agent_name" => f.route.name,
      "schedule" => %{"kind" => "every", "everyMs" => 600_000},
      "session_target" => "isolated",
      "delivery" => %{"mode" => "webhook", "to" => target},
      "max_runtime_ms" => 30_000,
      "enabled" => true,
      "deleteAfterRun" => false
    }

  defp invoke(session, f, tool, args) do
    call_id = "webhook-native-#{System.unique_integer([:positive])}"
    Agent.update(f.command, fn _ -> %{tool: tool, args: args, call_id: call_id} end)
    assert :ok = Worker.send_message(session.id, "Invoke #{call_id}")
    assert_receive {:native_following, ^call_id, following}, 10_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert [result] = Enum.filter(tool_results(session.id), &(&1.tool_use_id == call_id))
    assert result.is_error == false, "native #{tool} result: #{result.content}"
    assert_wire(following, [result])
    assert_persisted(session.id, [result])
    decoded = Jason.decode!(result.content)
    assert result.projection["result"]["structured"] == decoded
    {decoded, result}
  end

  defp assert_wire(request, parts) do
    for part <- parts do
      assert %{"role" => "tool", "tool_call_id" => part.tool_use_id, "content" => part.content} in request[
               "messages"
             ]
    end
  end

  defp assert_persisted(id, parts) do
    assert {:ok, turns} = Store.list_turns(id)

    for part <- parts do
      assert Enum.any?(
               for(turn <- turns, stored <- turn.parts, do: stored),
               &(&1[:type] == "tool_result" and &1[:content] == part.content and
                   &1[:projection] == part.projection)
             )
    end
  end

  defp assert_replay(id, parts) do
    [{old, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    monitor = Process.monitor(old)
    assert :ok = DynamicSupervisor.stop_session(id)
    assert_receive {:DOWN, ^monitor, :process, ^old, _}, 5_000
    assert :ok = Sessions.ensure_running(id)
    [{replacement, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    assert replacement != old
    assert :ok = Worker.send_message(id, "Replay webhook receipts")
    assert_receive {:replay_request, request}, 5_000
    assert_wire(request, parts)
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert tool_results(id) == parts
  end

  defp fixture(root, opts \\ []) do
    owner = self()
    http = Gaoxy.Test.open()
    receiver = Gaoxy.Test.open()
    provider = "webhook-#{Ecto.UUID.generate()}"
    command = start_supervised!({Agent, fn -> nil end}, id: :webhook_command)
    log = start_supervised!({Agent, fn -> [] end}, id: :webhook_log)

    assert :ok =
             Synapsis.Provider.Registry.register(provider, %{
               type: "openai",
               api_key: "test-key",
               base_url: String.trim_trailing(Gaoxy.Test.url(http), "/")
             })

    assert {:ok, agent} =
             Synapsis.AgentConfigs.create(%{
               name: provider,
               provider: provider,
               model: "creator-model",
               tools: [@create, @update, @history],
               tool_contract_version: 1,
               config: %{"workspace_path" => root}
             })

    assert {:ok, route} =
             Synapsis.AgentConfigs.create(%{
               name: provider <> "-route",
               provider: provider,
               model: "automation-model",
               tools: ["exec_command", @history],
               tool_contract_version: 1,
               config: %{"workspace_path" => root}
             })

    for path <- ["/first", "/second", "/empty"] do
      Gaoxy.Test.stub(receiver, "POST", path, fn conn ->
        assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
        assert {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(owner, {:webhook_received, path, Jason.decode!(body), self()})

        receive do
          :acknowledge_webhook -> Plug.Conn.send_resp(conn, 204, "")
        after
          10_000 -> raise "webhook receiver was not acknowledged"
        end
      end)
    end

    Gaoxy.Test.stub(http, "POST", "/v1/chat/completions", fn conn ->
      assert {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      Agent.update(log, &(&1 ++ [request]))

      cond do
        request["model"] == "automation-model" ->
          following = Enum.any?(request["messages"], &(&1["role"] == "tool"))
          send(owner, {:automation_wire, following, request, self()})

          if not following and Keyword.get(opts, :hold_model, true) do
            receive do
              :continue_automation_execution -> :ok
            after
              15_000 -> raise "automation model was not released"
            end
          end

          chunks =
            if Keyword.get(opts, :older_assistant, false) and not following do
              [
                Provider.text_chunk(@older),
                Provider.tool_call_chunk("exec_command", "webhook-empty-effect", %{
                  "cmd" => "printf effect >> webhook-empty-effect.txt",
                  "login" => false,
                  "yield_time_ms" => 1_000
                }),
                Provider.finish_chunk("tool_calls")
              ]
            else
              text = Keyword.get(opts, :final_text, @summary)

              if text == "",
                do: [Provider.finish_chunk("stop")],
                else: [Provider.text_chunk(text), Provider.finish_chunk("stop")]
            end

          Provider.send_sse(conn, chunks)

        List.last(user_texts(request)) == "Replay webhook receipts" ->
          send(owner, {:replay_request, request})
          respond(conn, "Receipts recalled")

        true ->
          current = Agent.get(command, & &1)

          following =
            Enum.any?(
              request["messages"],
              &(&1["role"] == "tool" and &1["tool_call_id"] == current.call_id)
            )

          if following do
            send(owner, {:native_following, current.call_id, request})
            respond(conn, "Native receipt acknowledged")
          else
            Provider.send_sse(conn, [
              Provider.tool_call_chunk(
                Synapsis.Provider.ToolName.encode(current.tool),
                current.call_id,
                current.args
              ),
              Provider.finish_chunk("tool_calls")
            ])
          end
      end
    end)

    on_exit(fn ->
      owned = Enum.filter(Runs.list_recent(limit: 1_000), &(&1.assistant_name == route.name))

      for run <- owned,
          run.status in ~w(queued running waiting_approval),
          do: Daemon.cancel(Daemon, run.id)

      for run <- owned, is_binary(run.session_id), do: Sessions.delete(run.session_id)
      Synapsis.AgentConfigs.delete(agent)
      Synapsis.AgentConfigs.delete(route)
      Synapsis.Provider.Registry.unregister(provider)
    end)

    %{
      root: root,
      agent: agent,
      route: route,
      provider: provider,
      receiver: receiver,
      http: http,
      command: command,
      log: log
    }
  end

  defp assert_fixtures_verified(f) do
    assert :ok = Gaoxy.Test.verify!(f.http)
    assert :ok = Gaoxy.Test.verify!(f.receiver)
  end

  defp source(f) do
    assert {:ok, session} =
             Sessions.create(f.agent.name, %{
               model: "creator-model",
               config: %{
                 "workspace_path" => f.root,
                 "subagents" => false,
                 "memory_context" => false
               }
             })

    assert :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session.id}")
    on_exit(fn -> Sessions.delete(session.id) end)
    session
  end

  defp respond(conn, text),
    do: Provider.send_sse(conn, [Provider.text_chunk(text), Provider.finish_chunk("stop")])

  defp tool_results(id),
    do: for(message <- Sessions.get_messages(id), %ToolResult{} = part <- message.parts, do: part)

  defp assistant_texts(id),
    do:
      for(
        %{role: "assistant", parts: parts} <- Sessions.get_messages(id),
        %Text{content: text} <- parts,
        do: text
      )

  defp user_texts(request),
    do: for(%{"role" => "user", "content" => text} <- request["messages"], do: content(text))

  defp content(text) when is_binary(text), do: text

  defp content(blocks) when is_list(blocks),
    do: Enum.map_join(blocks, "", &Map.get(&1, "text", ""))

  defp content(_), do: ""

  defp automation_requests(f),
    do:
      Agent.get(f.log, &Enum.filter(&1, fn request -> request["model"] == "automation-model" end))
end
