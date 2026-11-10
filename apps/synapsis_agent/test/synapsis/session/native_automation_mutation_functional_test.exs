defmodule Synapsis.Session.NativeAutomationMutationFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  import Synapsis.Agent.DaemonCase, only: [wait_for: 1, wait_for_ready: 0, wait_for_run: 2]
  alias Synapsis.Agent.{Routines, Runs}
  alias Synapsis.Agent.Heartbeat.LocalScheduler
  alias Synapsis.Agent.TestSupport.{AbortableHTTP, DeterministicProvider}
  alias Synapsis.Config.Store, as: ConfigStore
  alias Synapsis.Part.{Text, ToolResult}
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}
  alias Synapsis.Sessions

  @moduletag :tmp_dir
  @create "synapsis::automations_create"
  @update "synapsis::automations_update"
  @remove "synapsis::automations_remove"
  @prompt "\n  Updated authored effect  \n"
  @result "Updated automation result\nexact trailing bytes  "

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
    end)

    :ok
  end

  test "a later same-Agent session updates a native creation and its real timer announces to the original source",
       %{tmp_dir: root} do
    f = fixture(root, %{"enabled" => false})
    original = source(f)

    {created, creation_result} =
      invoke(original, f, "Create the automation", @create, create_args(f))

    id = created["id"]
    assert {:ok, before} = ConfigStore.get(:routine, id)
    assert before["automation_origin"] == %{"agent_id" => f.agent.id, "session_id" => original.id}
    enable_mutation_tools(f)
    editor = source(f)
    assert editor.id != original.id
    at = DateTime.utc_now() |> DateTime.add(5_000, :millisecond) |> DateTime.to_iso8601()

    {receipt, _} =
      invoke(editor, f, "Update the automation", @update, %{
        "source" => "routine",
        "id" => id,
        "patch" => %{
          "enabled" => true,
          "schedule" => %{"kind" => "at", "at" => at},
          "name" => "Updated route",
          "prompt" => @prompt,
          "agent_name" => f.route.name,
          "deleteAfterRun" => true
        }
      })

    assert receipt["persisted"] == true
    assert receipt["activation"] == "reloaded"
    assert receipt["source"] == "routine"
    assert receipt["id"] == id
    assert {:ok, saved} = ConfigStore.get(:routine, id)
    assert saved["automation_origin"] == before["automation_origin"]
    assert saved["prompt"] == @prompt
    assert saved["agent_name"] == f.route.name
    assert saved["schedule_generation"] != before["schedule_generation"]
    assert :ok = ConfigStore.reload(:routine)
    assert :ok = LocalScheduler.reload()
    assert {:ok, reloaded} = ConfigStore.get(:routine, id)
    assert reloaded["automation_origin"] == before["automation_origin"]

    assert {:ok, run} =
             wait_for(fn ->
               case Enum.find(Runs.list_recent(limit: 100), &(&1.routine_id == id)) do
                 nil -> :retry
                 run -> {:ok, run}
               end
             end)

    assert {:ok, completed} = wait_for_run(run.id, "completed")
    assert completed.capability_snapshot["agent_id"] == f.route.id
    assert completed.metadata["automation_origin"] == before["automation_origin"]
    assert completed.metadata["automation_context"]["status"] == "available"
    assert completed.summary == @result
    assert_receive {:effect_request, false, request}, 5_000

    assert user_texts(request) == [
             "Recent conversation:\n- User: Create the automation\n- Assistant: Mutation acknowledged\n\n" <>
               @prompt
           ]

    assert File.read!(Path.join(root, "mutated-automation-effect.txt")) == "effect"
    assert [effect_result] = tool_results(completed.session_id)
    assert effect_result.is_error == false
    assert_receive {:effect_request, true, following}, 5_000
    assert {"tool", effect_result.content} in wire_texts(following)
    assert_durable_tool_result(completed.session_id, effect_result)

    assert {:ok, :announced} =
             wait_for(fn ->
               if @result in assistant_texts(original.id), do: {:ok, :announced}, else: :retry
             end)

    assert assistant_texts(editor.id) == ["Mutation acknowledged"]
    assert Enum.count(assistant_texts(original.id), &(&1 == @result)) == 1

    assert {:ok, :removed} =
             wait_for(fn ->
               if ConfigStore.get(:routine, id) == {:error, :not_found},
                 do: {:ok, :removed},
                 else: :retry
             end)

    assert :ok = DynamicSupervisor.stop_session(original.id)
    assert :ok = Sessions.ensure_running(original.id)
    assert :ok = Worker.send_message(original.id, "Recall the original result")
    assert_receive {:replay_request, replay}, 5_000
    assert {"assistant", @result} in wire_texts(replay)
    assert {"tool", creation_result.content} in wire_texts(replay)
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert length(requests(f, "automation-model")) == 2
  end

  for operation <- [:disable, :remove] do
    test "native #{operation} persists before exact-source active and queued cancellation while its caller continues",
         ctx do
      native_retirement(unquote(operation), ctx.tmp_dir)
    end
  end

  defp native_retirement(operation, root) do
    f = fixture(root, %{"enabled" => true, "model" => "held-model"})
    original = source(f)
    {created, _} = invoke(original, f, "Create the automation", @create, create_args(f))
    id = created["id"]
    target = {"routine", id}

    assert {:ok, _} =
             ConfigStore.put(:heartbeat, %{
               "id" => id,
               "name" => "Same UUID sibling",
               "schedule" => "0 0 * * *",
               "prompt" => "Sibling native lifecycle",
               "agent_name" => f.route.name,
               "tool_profile" => "native_agent",
               "enabled" => true,
               "no_overlap" => false
             })

    assert :ok = LocalScheduler.reload()
    assert {:ok, %{run: active}} = Routines.run(target, :force)
    assert_receive {:held_request, handler}, 5_000
    assert {:ok, _} = wait_for_run(active.id, "running")
    assert {:ok, %{run: queued}} = Routines.run(target, :force)
    assert {:ok, sibling} = Routines.trigger({"heartbeat", id})
    enable_mutation_tools(f)
    manager = source(f)

    {tool, args} =
      if operation == :disable,
        do: {@update, %{"source" => "routine", "id" => id, "patch" => %{"enabled" => false}}},
        else: {@remove, %{"source" => "routine", "id" => id}}

    {receipt, native_result} = invoke(manager, f, "Manage the automation", tool, args)
    assert receipt["persisted"] == true
    assert receipt["activation"] == "retired"
    assert receipt["id"] == id
    assert receipt["cancellation"]["status"] == "cancellation_requested"
    assert receipt["cancellation"]["active_count"] == 1
    assert receipt["cancellation"]["queued_count"] == 1
    assert receipt["cancellation"]["cleanup_pending"] == true
    assert {:ok, _} = wait_for_run(active.id, "cancelled")
    assert {:ok, _} = wait_for_run(queued.id, "cancelled")
    assert_receive {:provider_disconnected, ^handler}, 5_000
    assert {:ok, sibling_completed} = wait_for_run(sibling.id, "completed")
    assert sibling_completed.summary == "Sibling completed"
    assert {:ok, _} = ConfigStore.get(:heartbeat, id)
    assert :sys.get_state(LocalScheduler).timers[target] == nil

    if operation == :disable do
      assert {:ok, saved} = ConfigStore.get(:routine, id)
      assert saved["enabled"] == false
      assert saved["automation_origin"]["session_id"] == original.id
    else
      assert receipt["removed"] == true
      assert {:error, :not_found} = ConfigStore.get(:routine, id)
    end

    assert :ok = ConfigStore.reload(:routine)
    assert :ok = Worker.send_message(manager.id, "Recall the original result")
    assert_receive {:replay_request, replay}, 5_000
    assert {"tool", native_result.content} in wire_texts(replay)
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert length(requests(f, "held-model")) == 1
  end

  defp create_args(f),
    do:
      Map.merge(
        %{
          "prompt" => "Initial automation",
          "provider" => f.override,
          "no_overlap" => false,
          "model" => "automation-model",
          "schedule" => %{"kind" => "every", "everyMs" => 600_000}
        },
        f.attrs
      )

  defp invoke(session, f, text, tool, arguments) do
    Agent.update(f.command, fn _ -> {tool, arguments} end)
    assert :ok = Worker.send_message(session.id, text)
    assert_receive {:mutation_following, request}, 10_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert [result] = tool_results(session.id)
    assert result.is_error == false
    assert {"tool", result.content} in wire_texts(request)
    assert_durable_tool_result(session.id, result)
    {Jason.decode!(result.content), result}
  end

  defp assert_durable_tool_result(id, result) do
    assert {:ok, turns} = Store.list_turns(id)

    assert Enum.any?(
             for(turn <- turns, part <- turn.parts, do: part),
             &(&1[:type] == "tool_result" and &1[:content] == result.content)
           )
  end

  defp fixture(root, attrs) do
    owner = self()
    http = Gaoxy.Test.open()
    provider = "mutation-#{Ecto.UUID.generate()}"
    override = provider <> "-override"
    command = start_supervised!({Agent, fn -> nil end}, id: :native_mutation_command)
    log = start_supervised!({Agent, fn -> [] end}, id: :native_mutation_log)

    for name <- [provider, override] do
      assert :ok =
               Synapsis.Provider.Registry.register(name, %{
                 type: "openai",
                 api_key: "test-key",
                 base_url: String.trim_trailing(Gaoxy.Test.url(http), "/")
               })
    end

    assert {:ok, agent} =
             Synapsis.AgentConfigs.create(%{
               name: provider,
               provider: provider,
               model: "creator-model",
               tools: [@create, "exec_command"],
               tool_contract_version: 1,
               config: %{"workspace_path" => root}
             })

    assert {:ok, route} =
             Synapsis.AgentConfigs.create(%{
               name: provider <> "-route",
               provider: provider,
               model: "automation-model",
               tools: ["exec_command"],
               tool_contract_version: 1,
               config: %{"workspace_path" => root}
             })

    Gaoxy.Test.stub(http, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      Agent.update(log, &(&1 ++ [request]))
      following = Enum.any?(request["messages"], &(&1["role"] == "tool"))
      prompt = List.last(user_texts(request))

      cond do
        request["model"] == "held-model" ->
          send(owner, {:held_request, self()})

          case AbortableHTTP.await(conn, :finish_native_target, 15_000, owner) do
            {:disconnected, conn} -> conn
            {:released, conn} -> respond(conn, "Target completed")
            {:timeout, _conn} -> raise "native target release timed out"
          end

        prompt == "Sibling native lifecycle" ->
          respond(conn, "Sibling completed")

        request["model"] == "automation-model" ->
          send(owner, {:effect_request, following, request})

          chunks =
            if following,
              do: [
                DeterministicProvider.text_chunk(@result),
                DeterministicProvider.finish_chunk("stop")
              ],
              else: [
                DeterministicProvider.tool_call_chunk("exec_command", "mutated-effect", %{
                  "cmd" => "printf effect >> mutated-automation-effect.txt",
                  "login" => false,
                  "yield_time_ms" => 1000
                }),
                DeterministicProvider.finish_chunk("tool_calls")
              ]

          DeterministicProvider.send_sse(conn, chunks)

        prompt == "Recall the original result" ->
          send(owner, {:replay_request, request})
          respond(conn, "Recalled")

        following ->
          send(owner, {:mutation_following, request})
          respond(conn, "Mutation acknowledged")

        true ->
          {tool, arguments} = Agent.get(command, & &1)

          DeterministicProvider.send_sse(conn, [
            DeterministicProvider.tool_call_chunk(tool, "native-mutation", arguments),
            DeterministicProvider.finish_chunk("tool_calls")
          ])
      end
    end)

    on_exit(fn ->
      owned =
        Enum.filter(
          Runs.list_recent(limit: 100),
          &(&1.assistant_name in [agent.name, route.name])
        )

      for run <- owned,
          run.status in ~w(queued running waiting_approval),
          do: Synapsis.Agent.Daemon.cancel(Synapsis.Agent.Daemon, run.id)

      for run <- owned, is_binary(run.session_id), do: Sessions.delete(run.session_id)

      Synapsis.Provider.Registry.unregister(provider)
      Synapsis.Provider.Registry.unregister(override)
    end)

    %{
      root: root,
      attrs: attrs,
      agent: agent,
      route: route,
      override: override,
      command: command,
      log: log
    }
  end

  defp respond(conn, text),
    do:
      DeterministicProvider.send_sse(
        conn,
        [DeterministicProvider.text_chunk(text), DeterministicProvider.finish_chunk("stop")]
      )

  defp enable_mutation_tools(f) do
    assert {:ok, _} =
             Synapsis.AgentConfigs.update(f.agent, %{
               tools: [@create, @update, @remove, "exec_command"]
             })
  end

  defp source(f) do
    assert {:ok, session} =
             Sessions.create(f.agent.name, %{
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

  defp tool_results(id),
    do: for(message <- Sessions.get_messages(id), %ToolResult{} = part <- message.parts, do: part)

  defp assistant_texts(id),
    do:
      for(
        %{role: "assistant", parts: parts} <- Sessions.get_messages(id),
        %Text{content: text} <- parts,
        do: text
      )

  defp user_texts(request), do: for({"user", text} <- wire_texts(request), do: text)

  defp wire_texts(request),
    do: Enum.map(request["messages"], &{&1["role"], content(&1["content"])})

  defp content(text) when is_binary(text), do: text

  defp content(blocks) when is_list(blocks),
    do: Enum.map_join(blocks, "", &Map.get(&1, "text", ""))

  defp content(_), do: ""
  defp requests(f, model), do: Agent.get(f.log, &Enum.filter(&1, fn r -> r["model"] == model end))
end
