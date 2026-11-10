defmodule Synapsis.Agent.DaemonNativeFunctionalTest do
  use Synapsis.Agent.DaemonCase, async: false
  @moduletag :functional

  alias Synapsis.Agent.TestSupport.DeterministicProvider, as: Provider
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}

  @moduletag :tmp_dir

  test "native direct effect completes durably and Worker restart replays once", ctx do
    {daemon, _} = start_test_daemon()
    {saved, fixture} = native_agent(ctx.tmp_dir, ["exec_command"])

    install_provider(fixture, "exec_command", %{
      "cmd" => "printf original >> daemon-effect.txt",
      "login" => false,
      "yield_time_ms" => 1000
    })

    assert {:ok, queued} = Daemon.submit(daemon, "Perform the native effect", native_opts(saved))
    assert {:ok, run} = wait_for_run(queued.id, "completed")
    assert run.capability_snapshot["tool_names"] == ["exec_command"]
    assert_receive {:native_request, 0, first}, 5_000
    assert tool_names(first) == ["exec_command"]
    assert_receive {:native_request, 1, following}, 5_000
    assert File.read!(Path.join(ctx.tmp_dir, "daemon-effect.txt")) == "original"

    assert [%ToolUse{tool: "exec_command", tool_use_id: "daemon-native-call"}] =
             parts(run.session_id, ToolUse)

    assert [%ToolResult{is_error: false} = result] = parts(run.session_id, ToolResult)
    assert_wire_result(following, result)
    assert {:ok, turns} = Store.list_turns(run.session_id)

    assert Enum.any?(
             for(turn <- turns, part <- turn.parts, do: part),
             &(&1[:type] == "tool_result" and &1[:content] == result.content)
           )

    assert {:ok, meta} = Store.get_meta(run.session_id)
    assert meta.config["daemon_run_id"] == run.id
    assert meta.config["daemon_run_tool_contract_version"] == 1

    [{old, _}] = Registry.lookup(Synapsis.Session.Registry, run.session_id)
    ref = Process.monitor(old)
    assert :ok = DynamicSupervisor.stop_session(run.session_id)
    assert_receive {:DOWN, ^ref, :process, ^old, _}, 5_000
    assert :ok = Synapsis.Sessions.ensure_running(run.session_id)
    [{fresh, _}] = Registry.lookup(Synapsis.Session.Registry, run.session_id)
    assert fresh != old
    assert :ok = Worker.send_message(run.session_id, "Recall the completed native effect")
    assert_receive {:native_request, 2, replay}, 5_000
    assert_wire_result(replay, result)

    assert {:ok, _} =
             wait_for(fn ->
               case Synapsis.Sessions.get(run.session_id) do
                 {:ok, %{status: "idle"}} -> {:ok, :idle}
                 _ -> :retry
               end
             end)

    assert File.read!(Path.join(ctx.tmp_dir, "daemon-effect.txt")) == "original"
    assert parts(run.session_id, ToolResult) == [result]
    assert Runs.get(run.id).capability_snapshot == queued.capability_snapshot
  end

  test "linked UUID Toolset replaces direct tools and records its exact provenance", ctx do
    {daemon, _} = start_test_daemon()

    assert {:ok, toolset} =
             Synapsis.Toolsets.create(%{
               name: "daemon-linked-#{Ecto.UUID.generate()}",
               tool_names: ["synapsis::todo_read"],
               tool_contract_version: 1
             })

    on_exit(fn -> Synapsis.Toolsets.delete(toolset) end)
    {saved, fixture} = native_agent(ctx.tmp_dir, ["exec_command"], %{toolset_ids: [toolset.id]})
    install_provider(fixture)

    assert {:ok, queued} =
             Daemon.submit(daemon, "Use linked native selection", native_opts(saved))

    assert {:ok, _} = wait_for_run(queued.id, "completed")
    assert_receive {:native_request, 0, request}, 5_000
    assert tool_names(request) == [Synapsis.Provider.ToolName.encode("synapsis::todo_read")]
    assert queued.capability_snapshot["tool_names"] == ["synapsis::todo_read"]
    assert [source] = queued.capability_snapshot["sources"]["toolsets"]

    assert source == %{
             "id" => toolset.id,
             "name" => toolset.name,
             "tool_contract_version" => 1,
             "tool_names" => ["synapsis::todo_read"]
           }
  end

  test "explicit empty selection and compatibility agent intent stay native", ctx do
    {daemon, _} = start_test_daemon()
    {saved, fixture} = native_agent(ctx.tmp_dir, [])
    install_provider(fixture)

    assert {:ok, queued} =
             Daemon.submit(daemon, "No tools needed", %{
               agent: saved.name,
               tool_profile: "native_agent"
             })

    assert {:ok, _} = wait_for_run(queued.id, "completed")
    assert_receive {:native_request, 0, request}, 5_000
    assert tool_names(request) == []
    assert queued.assistant_name == saved.name
    assert queued.tool_profile == "native_agent"
    assert queued.capability_snapshot["tool_names"] == []
  end

  test "queued selection and idempotent retry survive later Agent and Toolset edits", ctx do
    {daemon, _} = start_test_daemon()
    {blocker, blocking_fixture} = native_agent(ctx.tmp_dir, [])
    owner = self()

    Gaoxy.Test.stub(blocking_fixture, "POST", "/v1/chat/completions", fn conn ->
      send(owner, {:blocking_native_request, self()})

      receive do
        :release_native -> send_sse(conn, [text_chunk("released"), finish_chunk("stop")])
      after
        10_000 -> raise "native fixture release timed out"
      end
    end)

    assert {:ok, first} = Daemon.submit(daemon, "Hold queue", native_opts(blocker))
    assert_receive {:blocking_native_request, handler}, 5_000

    assert {:ok, toolset} =
             Synapsis.Toolsets.create(%{
               name: "daemon-queued-#{Ecto.UUID.generate()}",
               tool_names: ["synapsis::todo_read"],
               tool_contract_version: 1
             })

    on_exit(fn -> Synapsis.Toolsets.delete(toolset) end)
    {saved, fixture} = native_agent(ctx.tmp_dir, [], %{toolset_ids: [toolset.id]})
    install_provider(fixture)
    opts = Map.put(native_opts(saved), :idempotency_key, Ecto.UUID.generate())
    assert {:ok, queued} = Daemon.submit(daemon, "Frozen queued work", opts)
    assert queued.status == "queued"

    assert {:ok, _} =
             Synapsis.Toolsets.update(toolset, %{
               tool_names: ["exec_command"],
               tool_contract_version: 0
             })

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(saved, %{
               tools: ["write_stdin"],
               toolset_ids: [],
               tool_contract_version: 0,
               config:
                 Map.put(saved.config, "mcp_selection", %{"default" => "all", "sources" => %{}})
             })

    assert {:ok, duplicate} = Daemon.submit(daemon, "Frozen queued work", opts)
    assert duplicate.id == queued.id
    assert duplicate.capability_snapshot == queued.capability_snapshot
    send(handler, :release_native)
    assert {:ok, _} = wait_for_run(first.id, "completed")
    assert {:ok, completed} = wait_for_run(queued.id, "completed")
    assert_receive {:native_request, 0, request}, 5_000
    assert tool_names(request) == [Synapsis.Provider.ToolName.encode("synapsis::todo_read")]
    assert completed.capability_snapshot == queued.capability_snapshot
  end

  test "stored native HeartbeatConfig executes through its real adapter", ctx do
    {daemon, _} = start_test_daemon()
    {saved, fixture} = native_agent(ctx.tmp_dir, ["exec_command"])

    install_provider(fixture, "exec_command", %{
      "cmd" => "printf heartbeat >> heartbeat-effect.txt",
      "login" => false,
      "yield_time_ms" => 1000
    })

    assert {:ok, config} =
             Synapsis.Heartbeats.create(%{
               name: "native-heartbeat-#{Ecto.UUID.generate()}",
               agent_name: saved.name,
               enabled: true,
               prompt: "Complete heartbeat",
               tool_profile: "native_agent",
               schedule: "0 0 1 1 *"
             })

    on_exit(fn -> Synapsis.Heartbeats.delete(config) end)
    persisted = Synapsis.Heartbeats.get(config.id)
    assert persisted.tool_profile == "native_agent"
    assert {:ok, queued} = Synapsis.Agent.Heartbeat.Worker.execute(persisted, daemon)
    assert {:ok, completed} = wait_for_run(queued.id, "completed")
    assert completed.kind == "heartbeat"
    assert completed.heartbeat_id == config.id
    assert completed.capability_snapshot["tool_names"] == ["exec_command"]
    assert_receive {:native_request, 0, first}, 5_000
    assert tool_names(first) == ["exec_command"]
    assert_receive {:native_request, 1, following}, 5_000
    assert [%ToolResult{is_error: false} = result] = parts(completed.session_id, ToolResult)
    assert_wire_result(following, result)
    assert {:ok, turns} = Store.list_turns(completed.session_id)

    assert Enum.any?(
             for(turn <- turns, part <- turn.parts, do: part),
             &(&1[:type] == "tool_result" and &1[:content] == result.content)
           )

    assert File.read!(Path.join(ctx.tmp_dir, "heartbeat-effect.txt")) == "heartbeat"
  end

  test "shared native dream attrs preserve explicit profile", _ctx do
    assert {:ok, attrs} =
             Synapsis.Agent.Daemon.Execution.routine_attrs(:dream, %{
               prompt: "Dream",
               routine_id: Ecto.UUID.generate(),
               tool_profile: "native_agent"
             })

    assert attrs.tool_profile == "native_agent"
  end

  def native_agent(root, tools, extra \\ %{}) do
    fixture = Gaoxy.Test.open()
    suffix = Ecto.UUID.generate()
    provider = "native-daemon-#{suffix}"

    assert :ok =
             Synapsis.Provider.Registry.register(provider, %{
               type: "openai",
               api_key: "test-key",
               base_url: String.trim_trailing(Gaoxy.Test.url(fixture), "/")
             })

    assert {:ok, saved} =
             Synapsis.AgentConfigs.create(
               Map.merge(
                 %{
                   name: "native-daemon-#{suffix}",
                   provider: provider,
                   model: "native-daemon-model",
                   tools: tools,
                   tool_contract_version: 1,
                   permission_mode: "yolo",
                   config: %{"workspace_path" => root}
                 },
                 extra
               )
             )

    on_exit(fn ->
      for run <- Runs.list_recent(limit: 100),
          run.assistant_name == saved.name,
          is_binary(run.session_id),
          do: Synapsis.Sessions.delete(run.session_id)

      Synapsis.AgentConfigs.delete(saved)
      Synapsis.Provider.Registry.unregister(provider)
    end)

    {saved, fixture}
  end

  def native_opts(saved), do: %{assistant_name: saved.name, tool_profile: "native_agent"}

  def install_provider(fixture, tool \\ nil, arguments \\ %{}) do
    owner = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)

    Gaoxy.Test.stub(fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      index = Agent.get_and_update(counter, &{&1, &1 + 1})
      send(owner, {:native_request, index, request})

      if index == 0 and tool do
        Provider.send_sse(conn, [
          Provider.tool_call_chunk(
            Synapsis.Provider.ToolName.encode(tool),
            "daemon-native-call",
            arguments
          ),
          Provider.finish_chunk("tool_calls")
        ])
      else
        Provider.send_sse(conn, [
          Provider.text_chunk("native daemon complete"),
          Provider.finish_chunk("stop")
        ])
      end
    end)
  end

  def tool_names(request), do: Enum.map(request["tools"] || [], & &1["function"]["name"])

  def parts(id, module),
    do:
      for(
        message <- Synapsis.Sessions.get_messages(id),
        part <- message.parts,
        part.__struct__ == module,
        do: part
      )

  def assert_wire_result(request, result) do
    assert %{"role" => "tool", "tool_call_id" => result.tool_use_id, "content" => result.content} in request[
             "messages"
           ]
  end
end
