defmodule Synapsis.Session.NativeAutomationConfigurationFunctionalTest do
  use ExUnit.Case, async: false

  import Synapsis.Agent.DaemonCase, only: [wait_for: 1, wait_for_ready: 0, wait_for_run: 2]
  alias Synapsis.Agent.{Routines, Runs}
  alias Synapsis.Agent.Heartbeat.LocalScheduler
  alias Synapsis.Agent.TestSupport.DeterministicProvider
  alias Synapsis.Config.Store, as: ConfigStore
  alias Synapsis.Part.{Text, ToolResult}
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}
  alias Synapsis.Sessions

  @moduletag :tmp_dir
  @tool "synapsis::automations_create"
  @prompt "\n  Perform the scheduled effect  \n"
  @result "Created automation result\nexact trailing bytes  "

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

  test "native create captures the original creator, reloads TOML and announces a real timer result after route edits",
       ctx do
    target =
      DateTime.utc_now() |> DateTime.add(5_000, :millisecond) |> DateTime.truncate(:millisecond)

    f =
      fixture(ctx.tmp_dir, %{"schedule" => %{"kind" => "at", "at" => DateTime.to_iso8601(target)}})

    source = source(f)
    {receipt, result} = create(source, f)
    assert receipt["persisted"] == true
    assert receipt["activation"] == "reloaded"
    assert receipt["source"] == "routine"
    id = receipt["id"]

    assert {:ok, saved} =
             wait_for(fn ->
               case ConfigStore.get(:routine, id) do
                 {:ok, %{"next_run_at" => _} = saved} -> {:ok, saved}
                 _ -> :retry
               end
             end)

    assert saved["automation_origin"] == %{"agent_id" => f.agent.id, "session_id" => source.id}
    assert saved["session_target"] == "current"
    assert saved["delivery"] == %{"mode" => "announce"}
    assert saved["prompt"] == @prompt
    assert saved["name"] == "Perform the scheduled effect"
    assert saved["tool_profile"] == "native_agent"
    assert saved["deleteAfterRun"] == true
    assert :ok = ConfigStore.reload(:routine)
    assert :ok = LocalScheduler.reload()
    assert {:ok, ^saved} = ConfigStore.get(:routine, id)

    assert {:ok, edited} =
             Routines.update({"routine", id}, %{
               "agent_name" => f.route.name,
               "name" => "New execution route"
             })

    assert edited["automation_origin"] == saved["automation_origin"]
    assert edited["schedule_generation"] == saved["schedule_generation"]

    assert {:ok, run} =
             wait_for(fn ->
               case Enum.find(Runs.list_recent(limit: 100), &(&1.routine_id == id)) do
                 nil -> :retry
                 run -> {:ok, run}
               end
             end)

    assert {:ok, completed} = wait_for_run(run.id, "completed")
    assert completed.capability_snapshot["agent_id"] == f.route.id
    assert completed.metadata["automation_origin"] == saved["automation_origin"]
    assert completed.metadata["automation_context"]["status"] == "available"
    assert completed.provider == f.override
    assert completed.model == "automation-model"
    assert_receive {:automation_request, false, request}, 5_000

    assert user_texts(request) == [
             "Recent conversation:\n- User: Create the scheduled reminder\n- Assistant: Creation acknowledged\n\n" <>
               @prompt
           ]

    assert_effect(completed, ctx.tmp_dir)

    assert {:ok, :announced} =
             wait_for(fn ->
               if @result in assistant_texts(source.id), do: {:ok, :announced}, else: :retry
             end)

    assert Enum.count(assistant_texts(source.id), &(&1 == @result)) == 1
    assert length(requests(f, "creator-model")) == 2

    assert {:ok, :retired} =
             wait_for(fn ->
               if ConfigStore.get(:routine, id) == {:error, :not_found},
                 do: {:ok, :retired},
                 else: :retry
             end)

    assert :ok = DynamicSupervisor.stop_session(source.id)
    assert :ok = Sessions.ensure_running(source.id)
    assert :ok = Worker.send_message(source.id, "Recall the created result")
    assert_receive {:source_replay, replay}, 5_000
    assert {"assistant", @result} in wire_texts(replay)
    assert {"tool", result.content} in wire_texts(replay)
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert Enum.count(assistant_texts(source.id), &(&1 == @result)) == 1
    assert length(requests(f, "automation-model")) == 2
  end

  test "native isolated disabled creation preserves explicit none and a forced run leaves the source unchanged",
       ctx do
    f =
      fixture(ctx.tmp_dir, %{
        "schedule" => %{"kind" => "every", "everyMs" => 600_000},
        "enabled" => false,
        "session_target" => "isolated",
        "delivery" => %{"mode" => "none"}
      })

    source = source(f)
    {receipt, _} = create(source, f)
    assert receipt["enabled"] == false
    assert receipt["session_target"] == "isolated"
    assert receipt["delivery"] == %{"mode" => "none"}
    assert {:ok, %{enqueued: true, run: run}} = Routines.run({"routine", receipt["id"]}, :force)
    assert {:ok, completed} = wait_for_run(run.id, "completed")
    assert completed.metadata["automation_context"]["status"] == "omitted"
    assert completed.metadata["automation_delivery"]["status"] == "suppressed"
    assert_receive {:automation_request, false, request}, 5_000
    assert user_texts(request) == [@prompt]
    assert_effect(completed, ctx.tmp_dir)
    assert assistant_texts(source.id) == ["Creation acknowledged"]
    assert length(requests(f, "creator-model")) == 2
    assert {:ok, saved} = ConfigStore.get(:routine, receipt["id"])
    assert saved["enabled"] == false
  end

  test "a valid large display name preserves the successful minimum creation receipt", ctx do
    name = String.duplicate("n", 40_000)

    f =
      fixture(ctx.tmp_dir, %{
        "name" => name,
        "enabled" => false,
        "schedule" => %{"kind" => "every", "everyMs" => 600_000}
      })

    source = source(f)
    {receipt, _} = create(source, f)
    assert receipt["persisted"] == true
    assert receipt["activation"] == "reloaded"
    assert receipt["projection_truncated"] == true
    assert receipt["source"] == "routine"
    assert {:ok, saved} = ConfigStore.get(:routine, receipt["id"])
    assert saved["name"] == name
    assert saved["enabled"] == false
    assert saved["automation_origin"]["session_id"] == source.id
    assert byte_size(Jason.encode!(receipt)) < 1_024
  end

  defp create(source, _f) do
    assert :ok = Worker.send_message(source.id, "Create the scheduled reminder")
    assert_receive {:creation_following, request}, 10_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000

    assert [result] =
             for(
               message <- Sessions.get_messages(source.id),
               %ToolResult{} = part <- message.parts,
               do: part
             )

    assert result.is_error == false
    assert {"tool", result.content} in wire_texts(request)
    assert {:ok, turns} = Store.list_turns(source.id)

    assert Enum.any?(
             for(turn <- turns, part <- turn.parts, do: part),
             &(&1[:type] == "tool_result" and &1[:content] == result.content)
           )

    {Jason.decode!(result.content), result}
  end

  defp assert_effect(run, root) do
    assert run.summary == @result
    assert File.read!(Path.join(root, "created-automation-effect.txt")) == "effect"

    assert [%ToolResult{is_error: false} = result] =
             for(
               message <- Sessions.get_messages(run.session_id),
               %ToolResult{} = part <- message.parts,
               do: part
             )

    assert_receive {:automation_request, true, following}, 5_000
    assert {"tool", result.content} in wire_texts(following)
    assert {:ok, turns} = Store.list_turns(run.session_id)

    assert Enum.any?(
             for(turn <- turns, part <- turn.parts, do: part),
             &(&1[:type] == "tool_result" and &1[:content] == result.content)
           )
  end

  defp fixture(root, attrs) do
    owner = self()
    http = Gaoxy.Test.open()
    provider = "create-#{Ecto.UUID.generate()}"
    override = provider <> "-override"
    log = start_supervised!({Agent, fn -> [] end})

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
               tools: [@tool, "exec_command"],
               tool_contract_version: 1,
               config: %{"workspace_path" => root}
             })

    assert {:ok, route} =
             Synapsis.AgentConfigs.create(%{
               name: provider <> "-route",
               provider: provider,
               model: "creator-model",
               tools: ["exec_command"],
               tool_contract_version: 1,
               config: %{"workspace_path" => root}
             })

    arguments =
      Map.merge(
        %{"prompt" => @prompt, "provider" => override, "model" => "automation-model"},
        attrs
      )

    Gaoxy.Test.stub(http, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      Agent.update(log, &(&1 ++ [request]))
      following = Enum.any?(request["messages"], &(&1["role"] == "tool"))

      chunks =
        cond do
          request["model"] == "automation-model" ->
            send(owner, {:automation_request, following, request})

            if following do
              [
                DeterministicProvider.text_chunk(@result),
                DeterministicProvider.finish_chunk("stop")
              ]
            else
              [
                DeterministicProvider.tool_call_chunk("exec_command", "created-effect", %{
                  "cmd" => "printf effect >> created-automation-effect.txt",
                  "login" => false,
                  "yield_time_ms" => 1000
                }),
                DeterministicProvider.finish_chunk("tool_calls")
              ]
            end

          List.last(user_texts(request)) == "Recall the created result" ->
            send(owner, {:source_replay, request})

            [
              DeterministicProvider.text_chunk("Recalled"),
              DeterministicProvider.finish_chunk("stop")
            ]

          following ->
            send(owner, {:creation_following, request})

            [
              DeterministicProvider.text_chunk("Creation acknowledged"),
              DeterministicProvider.finish_chunk("stop")
            ]

          true ->
            [
              DeterministicProvider.tool_call_chunk(@tool, "create-routine", arguments),
              DeterministicProvider.finish_chunk("tool_calls")
            ]
        end

      DeterministicProvider.send_sse(conn, chunks)
    end)

    on_exit(fn ->
      for run <- Runs.list_recent(limit: 100),
          run.assistant_name in [agent.name, route.name],
          is_binary(run.session_id),
          do: Sessions.delete(run.session_id)

      Synapsis.Provider.Registry.unregister(provider)
      Synapsis.Provider.Registry.unregister(override)
    end)

    %{root: root, agent: agent, route: route, override: override, log: log}
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
