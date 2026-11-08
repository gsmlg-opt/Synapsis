defmodule Synapsis.Session.MCPRefreshTest do
  use ExUnit.Case, async: false
  alias Synapsis.Agent.TestSupport.{AbortableHTTP, DeterministicProvider, SessionHarness}
  alias Synapsis.MCP.Server
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{Store, Worker}
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    owner = self()
    state = start_supervised!({Agent, fn -> %{field: "first", hold: false, fail: false} end})
    fixture = Gaoxy.Test.open()

    Gaoxy.Test.stub(fixture, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      req = Jason.decode!(body)
      current = Agent.get(state, & &1)

      {conn, result} =
        case req["method"] do
          "initialize" ->
            {conn,
             %{
               "protocolVersion" => req["params"]["protocolVersion"],
               "capabilities" => %{"tools" => %{}},
               "serverInfo" => %{"name" => "native-worker", "version" => "1"}
             }}

          "tools/list" ->
            conn =
              if current.hold do
                send(owner, {:source_discovery, self()})

                receive do
                  :release_source -> :ok
                after
                  5_000 -> raise "source discovery was not released"
                end

                conn
              else
                conn
              end

            {conn,
             if(current.fail,
               do: :failed,
               else: %{
                 "tools" => [
                   %{
                     "name" => "read",
                     "description" => "Native Worker MCP",
                     "annotations" => %{"readOnlyHint" => true},
                     "inputSchema" => %{
                       "type" => "object",
                       "properties" => %{current.field => %{"type" => "string"}},
                       "additionalProperties" => false
                     }
                   }
                 ]
               }
             )}

          "tools/call" ->
            send(owner, {:native_source_called, req["params"]})

            {conn,
             %{
               "content" => [
                 %{
                   "type" => "text",
                   "text" => "source result",
                   "annotations" => %{"priority" => 0.5},
                   "_meta" => %{"source" => "fixture"}
                 }
               ],
               "structuredContent" => %{"retained" => true},
               "isError" => false
             }}

          _ ->
            {conn, %{}}
        end

      cond do
        result == :failed ->
          Plug.Conn.resp(conn, 503, "source offline")

        Map.has_key?(req, "id") ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{"jsonrpc" => "2.0", "id" => req["id"], "result" => result})
          )

        true ->
          Plug.Conn.resp(conn, 202, "")
      end
    end)

    for method <- ["GET", "DELETE"],
        do: Gaoxy.Test.stub(fixture, method, "/mcp", &Plug.Conn.resp(&1, 200, ""))

    {:ok, source} =
      Synapsis.MCPConfigs.create(%{
        name: "worker-mcp-#{System.unique_integer([:positive])}",
        transport: "streamable_http",
        url: String.trim_trailing(Gaoxy.Test.url(fixture), "/")
      })

    pid = start_supervised!(Supervisor.child_spec({Server, source}, restart: :temporary))
    assert :ok = Server.await_ready(pid)

    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    name = "mcp::#{source.id}::read"
    assert {:ok, _} = Synapsis.AgentConfigs.update(harness.agent_config, %{tools: [name]})
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)

    on_exit(fn ->
      SessionHarness.cleanup!(harness)
      Synapsis.MCPConfigs.delete(source)
    end)

    %{
      harness: harness,
      id: harness.session.id,
      name: name,
      source: source,
      source_pid: pid,
      source_state: state
    }
  end

  test "Worker refreshes selected source schemas and exact revisions before each provider turn",
       ctx do
    provider(ctx, false)

    for {field, revision} <- [{"second", 2}, {"third", 3}] do
      Agent.update(ctx.source_state, &%{&1 | field: field, hold: true})
      assert :ok = Worker.send_message(ctx.id, "Use current source schema")
      assert_receive {:source_discovery, discovery}, 5_000
      assert Task.await(Task.async(fn -> Worker.snapshot(ctx.id) end), 1_000).session.id == ctx.id
      send(discovery, :release_source)
      assert_receive {:mcp_worker_provider, request, handler}, 5_000
      assert [%{"function" => function}] = request["tools"]
      assert function["name"] == ToolName.encode(ctx.name)
      assert function["parameters"]["properties"] == %{field => %{"type" => "string"}}
      runtime = runtime(ctx.id)
      descriptor = :sys.get_state(runtime.root).catalog.registry.tools[ctx.name]
      assert descriptor.backend == Synapsis.Agent.Tools.MCP
      assert descriptor.tool_revision == revision
      assert descriptor.backend_context.source.source_id == ctx.source.id
      send(handler, :release_provider)
      assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    end
  end

  test "native MCP effects persist original text and structured result through a real Worker",
       ctx do
    provider(ctx, true)
    assert :ok = Worker.send_message(ctx.id, "Call the selected source tool")
    assert_receive {:mcp_worker_provider, _, handler}, 5_000
    runtime = runtime(ctx.id)
    send(handler, :release_provider)
    assert_receive {:native_source_called, %{"name" => "read", "arguments" => %{}}}, 5_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert [%Synapsis.Part.ToolResult{projection: projection, is_error: false}] = results(ctx.id)

    assert projection["result"]["content"] == [
             %{
               "type" => "text",
               "text" => "source result",
               "annotations" => %{"priority" => 0.5},
               "_meta" => %{"source" => "fixture"}
             }
           ]

    assert projection["result"]["structured"] == %{"retained" => true}
    assert length(intents(runtime)) == 1
    assert {:ok, turns} = Store.list_turns(ctx.id)
    assert Enum.any?(turns, fn t -> Enum.any?(t.parts, &(&1[:projection] == projection)) end)
  end

  test "write denial blocks an untrusted readOnly MCP source before native intent", ctx do
    raw = Store.get_value(ctx.id, "permission")
    assert :ok = Store.put_value(ctx.id, "permission", %{raw | allow_write: :deny})
    provider(ctx, true)
    assert :ok = Worker.send_message(ctx.id, "Try the selected source tool")
    assert_receive {:mcp_worker_provider, _, handler}, 5_000
    runtime = runtime(ctx.id)
    send(handler, :release_provider)
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    refute_receive {:native_source_called, _}
    assert intents(runtime) == []
    assert [%Synapsis.Part.ToolResult{is_error: true}] = results(ctx.id)
  end

  test "cancellation during discovery prevents late source completion from starting a provider",
       ctx do
    provider(ctx, false)
    Agent.update(ctx.source_state, &%{&1 | hold: true})
    assert :ok = Worker.send_message(ctx.id, "Cancel source discovery")
    assert_receive {:source_discovery, discovery}, 5_000
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, ctx.id)
    {_, data} = :sys.get_state(worker)
    ref = Process.monitor(data.runtime_task.pid)
    assert :ok = Worker.cancel(ctx.id)
    assert_receive {:DOWN, ^ref, :process, _, _}, 1_000
    send(discovery, :release_source)
    assert :waiting = Worker.get_status(ctx.id)
    refute_receive {:mcp_worker_provider, _, _}
  end

  test "an unavailable explicitly selected source fails before the provider request", ctx do
    provider(ctx, false)
    Agent.update(ctx.source_state, &%{&1 | fail: true})
    assert :ok = Worker.send_message(ctx.id, "Keep my selected tools")
    assert_receive {:run_event, %{type: "session.failed"}}, 10_000
    refute_receive {:mcp_worker_provider, _, _}
    refute_receive {:native_source_called, _}
    assert results(ctx.id) == []
  end

  test "stopping a Worker during discovery prevents any late provider request", ctx do
    provider(ctx, false)
    Agent.update(ctx.source_state, &%{&1 | hold: true})
    assert :ok = Worker.send_message(ctx.id, "Stop source discovery")
    assert_receive {:source_discovery, discovery}, 5_000
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, ctx.id)
    {_, data} = :sys.get_state(worker)
    ref = Process.monitor(data.runtime_task.pid)
    assert :ok = Synapsis.Session.DynamicSupervisor.stop_session(ctx.id)
    assert_receive {:DOWN, ^ref, :process, _, _}, 1_000
    send(discovery, :release_source)
    refute_receive {:mcp_worker_provider, _, _}
  end

  test "source revocation while the provider waits prevents intent and dispatch", ctx do
    provider(ctx, true)
    assert :ok = Worker.send_message(ctx.id, "Recheck source availability")
    assert_receive {:mcp_worker_provider, _, handler}, 5_000
    runtime = runtime(ctx.id)
    assert {:ok, _} = Synapsis.MCPConfigs.update(ctx.source, %{enabled: false})
    send(handler, :release_provider)
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    refute_receive {:native_source_called, _}
    assert intents(runtime) == []
    assert [%Synapsis.Part.ToolResult{is_error: true}] = results(ctx.id)
  end

  test "saved legacy names and per-source selection both retain the native source tool", ctx do
    provider(ctx, false)

    for attrs <- [
          %{tools: ["mcp:#{ctx.source.name}:read"]},
          %{
            tools: [],
            config:
              Map.put(ctx.harness.agent_config.config, "mcp_selection", %{
                "default" => "selected",
                "sources" => %{ctx.source.id => %{"mode" => "all"}}
              })
          }
        ] do
      assert {:ok, _} = Synapsis.AgentConfigs.update(ctx.harness.agent_config, attrs)
      assert :ok = Worker.send_message(ctx.id, "Use saved source selection")
      assert_receive {:mcp_worker_provider, request, handler}, 5_000
      assert [%{"function" => %{"name" => name}}] = request["tools"]
      assert name == ToolName.encode(ctx.name)
      send(handler, :release_provider)
      assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    end
  end

  defp provider(ctx, call?) do
    owner = self()

    Gaoxy.Test.stub(ctx.harness.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      has_result = Enum.any?(request["messages"], &(&1["role"] == "tool"))

      conn =
        if has_result do
          conn
        else
          send(owner, {:mcp_worker_provider, request, self()})
          {:released, conn} = AbortableHTTP.await(conn, :release_provider, 5_000, owner)
          conn
        end

      chunks =
        if call? and not has_result do
          [
            DeterministicProvider.tool_call_chunk(
              ToolName.encode(ctx.name),
              "mcp-worker-call",
              %{}
            ),
            DeterministicProvider.finish_chunk("tool_calls")
          ]
        else
          [
            DeterministicProvider.text_chunk("MCP turn complete"),
            DeterministicProvider.finish_chunk("stop")
          ]
        end

      DeterministicProvider.send_sse(conn, chunks)
    end)
  end

  defp runtime(id) do
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    {_, data} = :sys.get_state(worker)
    state = :sys.get_state(data.runtime_pid)
    %{root: state.root, store: state.store, run_id: state.run_id}
  end

  defp results(id),
    do:
      for(
        m <- Synapsis.Sessions.get_messages(id),
        r = %Synapsis.Part.ToolResult{} <- m.parts,
        do: r
      )

  defp intents(runtime) do
    {:ok, aggregate} = Synapsis.Runtime.Store.load(runtime.store.namespace, runtime.run_id)
    Enum.filter(aggregate.run.execution_intents, fn {_, i} -> i.type == :tool end)
  end
end
