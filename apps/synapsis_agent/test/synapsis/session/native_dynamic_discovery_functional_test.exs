defmodule Synapsis.Session.NativeDynamicDiscoveryFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional
  alias Backplane.AgentRuntime.Conversation
  alias Backplane.AgentRuntime.Codex.{ResourceRegistry, Session}
  alias Backplane.AgentRuntime.Codex.CodeMode, as: NativeCodeMode
  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Agent.Runtime.ProviderMessages
  alias Synapsis.MCP.Server
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}
  @moduletag :tmp_dir
  @file_tool "synapsis::file_read"
  @status "synapsis::session_status"
  @summary "synapsis::session_summarize"
  @selected ~w(exec_command clock::curr_time exec wait)
  @raw "read::raw"

  for mode <- [:direct, :nested] do
    @mode mode
    test "Worker #{@mode} search publishes selected host and MCP tools, persists and replays once",
         %{tmp_dir: root} do
      ctx = setup_context(root)
      install_provider(ctx, @mode)
      SessionHarness.ensure_running!(ctx.id)
      assert :ok = Worker.send_message(ctx.id, "Discover and use the selected read tools")
      assert_receive {:dynamic_runtime, runtime}, 10_000
      {first, handler} = request(0, runtime, 1)

      assert wire_names(first) ==
               encoded((ctx.selection -- [@file_tool, ctx.mcp_name]) ++ ["tool_search"])

      adapter = :sys.get_state(runtime.adapter)
      entry = adapter.tool_contexts[{runtime.run_id, 1}]
      issued = entry.snapshot.issued_descriptors
      discovery = entry.discovery
      assert Process.alive?(discovery.pid)
      discovery_monitor = Process.monitor(discovery.pid)
      assert issued[@file_tool].backend_context.catalog_revision == 1
      assert issued[ctx.mcp_name].backend_context.catalog_revision == 1
      send(handler, :deliver)
      {published, handler} = request(1, runtime, 2)
      assert wire_names(published) == encoded(ctx.selection ++ ["tool_search"])
      current = :sys.get_state(runtime.root).catalog
      assert current.registry.tools[@file_tool] === issued[@file_tool]
      assert current.registry.tools[ctx.mcp_name] === issued[ctx.mcp_name]

      assert Enum.any?(
               published["input"],
               &(&1["call_id"] == "discover" and String.contains?(&1["output"] || "", "staged"))
             )

      send(handler, :deliver)

      final_index =
        if @mode == :nested do
          {yielded_request, handler} = request(2, runtime, 2)
          yielded = wire_result(yielded_request, runtime, "code-start")
          assert yielded["status"] == "yielded"
          assert yielded["value"] == "catalog-pause"

          handle = %{
            resource_id: yielded["cell_id"],
            owner_id: runtime.binding.owner_id,
            incarnation: runtime.binding.incarnation,
            kind: :continuation
          }

          assert {:ok, deno} =
                   ResourceRegistry.fetch(
                     runtime.binding.resource_registry,
                     handle,
                     handle.owner_id
                   )

          assert Process.alive?(deno)
          assert {:ok, os} = NativeCodeMode.Worker.os_identity(deno)
          assert File.exists?("/proc/#{os.pid}")
          monitor = Process.monitor(deno)
          send(handler, {:deliver, yielded["cell_id"]})
          {following, handler} = request(3, runtime, 2)
          assert wire_result(following, runtime, "code-resume")["status"] == "completed"
          send(handler, :deliver)
          assert_receive {:DOWN, ^monitor, :process, ^deno, _}, 5_000
          assert_os_reaped(os.pid)
          4
        else
          {following, handler} = request(2, runtime, 2)

          assert Enum.any?(
                   following["input"],
                   &(&1["call_id"] == "file" and
                       String.contains?(&1["output"] || "", "pinned catalog fixture"))
                 )

          send(handler, :deliver)
          3
        end

      assert_receive {:run_event, %{type: "session.completed"}}, 15_000
      assert_receive {:DOWN, ^discovery_monitor, :process, _, _}, 5_000
      assert %{phase: :idle} = Session.status(runtime.binding.session)
      parts = tool_parts(ctx.id)
      uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
      results = Enum.filter(parts, &match?(%ToolResult{}, &1))
      assert Enum.all?(results, &(&1.is_error == false))

      assert Enum.map(uses, & &1.tool_use_id) ==
               if(@mode == :nested,
                 do: ~w(discover code-start code-resume),
                 else: ~w(discover file mcp shell)
               )

      assert_part_round_trips(parts)
      assert_durable_parts(ctx.id, uses, results)
      assert length(Agent.get(ctx.effects, & &1)) == 1
      assert File.read!(Path.join(root, "catalog-count.txt")) == "run\n"
      operations = operations(runtime, :tool)

      for operation <- operations do
        assert operation.catalog_revision ==
                 if(operation.tool_call_id == "discover" or operation.tool_name == "tool_search",
                   do: 1,
                   else: 2
                 )

        assert operation.run_id == runtime.run_id
        assert operation.incarnation == runtime.binding.run_incarnation
      end

      assert Enum.any?(operations, &(&1.tool_name == ctx.mcp_name))
      assert Enum.any?(operations, &(&1.tool_name == @file_tool))
      assert agent_config(ctx).tools == ctx.selection
      replay(ctx, runtime, final_index, parts, uses, results)
    end
  end

  test "children use their pinned inherited inventory and finish discovery after the parent completes",
       %{tmp_dir: root} do
    ctx = setup_context(root, true)
    install_child_provider(ctx)
    SessionHarness.ensure_running!(ctx.id)
    assert :ok = Worker.send_message(ctx.id, "Compare before and after children")
    assert_receive {:children_runtime, runtime}, 10_000
    assert_receive {:child_request, :before, 0, before_request, _}, 15_000
    assert wire_names(before_request) == encoded(ctx.selection -- [@file_tool, ctx.mcp_name])
    assert_receive {:child_request, :after, 0, after_request, handler}, 15_000

    assert wire_names(after_request) ==
             encoded((ctx.selection -- [@file_tool, ctx.mcp_name]) ++ ["tool_search"])

    state = :sys.get_state(runtime.adapter)

    [{{child_run, child_incarnation}, child_entry}] =
      for {key = {run, _}, entry} <- state.tool_contexts,
          run != runtime.run_id and not is_nil(entry.discovery),
          do: {key, entry}

    root_record = state.tool_contexts[{runtime.run_id, 1}].discovery
    child_record = child_entry.discovery
    assert child_record.pid != root_record.pid
    assert child_record.binding.owner_id != root_record.binding.owner_id

    assert Enum.sort(Map.keys(child_entry.snapshot.issued_descriptors)) ==
             Enum.sort(ctx.selection ++ ["tool_search"])

    root_monitor = Process.monitor(root_record.pid)
    child_monitor = Process.monitor(child_record.pid)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    assert_receive {:DOWN, ^root_monitor, :process, _, _}, 5_000
    assert Process.alive?(child_record.pid)

    assert :sys.get_state(runtime.adapter).tool_contexts[{child_run, child_incarnation}].discovery ==
             child_record

    send(handler, :finish_child_discovery)
    assert_receive {:child_request, :after, 1, published, _}, 15_000
    assert wire_names(published) == encoded(ctx.selection ++ ["tool_search"])
    assert_receive {:child_request, :after, 2, used, _}, 15_000

    assert Enum.any?(
             used["input"],
             &(&1["call_id"] == "child-file" and
                 String.contains?(&1["output"] || "", "pinned catalog fixture"))
           )

    assert_receive {:DOWN, ^child_monitor, :process, _, _}, 5_000

    await_cleanup(
      runtime.adapter,
      {child_run, child_incarnation},
      System.monotonic_time(:millisecond) + 5_000
    )

    assert :sys.get_state(runtime.adapter).discovery_cleanup[{runtime.run_id, 1}] == :ok
    assert length(Agent.get(ctx.effects, & &1)) == 1

    assert {:ok, child_run_record} =
             Synapsis.Runtime.Store.load(runtime.store.namespace, child_run)

    tool_operations =
      for {_, intent} <- child_run_record.run.execution_intents,
          intent.type == :tool,
          do: intent.operation

    assert Enum.any?(
             tool_operations,
             &(&1.tool_name == "tool_search" and &1.catalog_revision == 1)
           )

    assert Enum.any?(
             tool_operations,
             &(&1.tool_name == ctx.mcp_name and &1.catalog_revision == 2)
           )

    assert agent_config(ctx).tools == ctx.selection
  end

  defp await_cleanup(adapter, key, deadline) do
    state = :sys.get_state(adapter)

    if state.discovery_cleanup[key] != :ok and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(10)
      await_cleanup(adapter, key, deadline)
    else
      assert state.discovery_cleanup[key] == :ok
      refute Map.has_key?(state.tool_contexts, key)
    end
  end

  defp install_child_provider(ctx) do
    owner = self()

    Agent.update(
      ctx.harness.counter,
      &Map.put(&1, :child_counts, %{root: 0, before: 0, after: 0})
    )

    Gaoxy.Test.stub(ctx.harness.provider.fixture, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      last_user = request["input"] |> Enum.filter(&(&1["role"] == "user")) |> List.last()

      text =
        case last_user && last_user["content"] do
          value when is_binary(value) -> value
          value when is_list(value) -> Enum.map_join(value, &(&1["text"] || ""))
          _ -> ""
        end

      role =
        case text do
          "child-before-discovery" -> :before
          "child-after-discovery" -> :after
          _ -> :root
        end

      index =
        Agent.get_and_update(ctx.harness.counter, fn state ->
          {state.child_counts[role],
           %{
             state
             | child_counts: Map.update!(state.child_counts, role, &(&1 + 1)),
               provider_requests: state.provider_requests ++ [request]
           }}
        end)

      if {role, index} == {:root, 0},
        do: send(owner, {:children_runtime, initial_runtime(ctx.id)})

      send(owner, {:child_request, role, index, request, self()})

      case {role, index} do
        {:root, 0} ->
          function_calls(conn, [
            {"before-spawn", "spawn_agent",
             %{
               "task_name" => "before_discovery",
               "message" => "child-before-discovery",
               "fork_turns" => "none"
             }}
          ])

        {:root, 1} ->
          function_calls(conn, [{"before-wait", "wait_agent", %{"timeout_ms" => 15_000}}])

        {:root, 2} ->
          function_calls(conn, [
            {"parent-search", "tool_search", %{"query" => "read", "limit" => 2}}
          ])

        {:root, 3} ->
          function_calls(conn, [
            {"after-spawn", "spawn_agent",
             %{
               "task_name" => "after_discovery",
               "message" => "child-after-discovery",
               "fork_turns" => "none"
             }}
          ])

        {:after, 0} ->
          receive do
            :finish_child_discovery ->
              function_calls(conn, [
                {"child-search", "tool_search", %{"query" => "read", "limit" => 2}}
              ])
          after
            15_000 -> raise "child discovery handshake timed out"
          end

        {:after, 1} ->
          function_calls(conn, [
            {"child-file", @file_tool, %{"path" => "catalog.txt"}},
            {"child-mcp", ctx.mcp_name, %{"label" => "child"}}
          ])

        _ ->
          sse(conn, [
            %{"type" => "response.output_text.delta", "delta" => "Child comparison complete"},
            completed([])
          ])
      end
    end)
  end

  defp request(index, runtime, revision) do
    assert_receive {:dynamic_request, ^index, request, handler}, 15_000
    assert Conversation.status(runtime.root).catalog_revision == revision
    assert Enum.any?(operations(runtime, :provider), &(&1.catalog_revision == revision))
    {request, handler}
  end

  defp wire_names(request), do: Enum.sort(Enum.map(request["tools"], & &1["name"]))
  defp encoded(names), do: names |> Enum.map(&ToolName.encode/1) |> Enum.sort()
  defp agent_config(ctx), do: Synapsis.AgentConfigs.get(ctx.harness.agent_config.id)

  defp install_provider(ctx, mode) do
    owner = self()

    Gaoxy.Test.stub(ctx.harness.provider.fixture, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      index =
        Agent.get_and_update(ctx.harness.counter, fn state ->
          {length(state.provider_requests),
           %{state | provider_requests: state.provider_requests ++ [request]}}
        end)

      if index == 0, do: send(owner, {:dynamic_runtime, initial_runtime(ctx.id)})
      send(owner, {:dynamic_request, index, request, self()})

      delivery =
        receive do
          :deliver -> :deliver
          {:deliver, cell} -> cell
        after
          15_000 -> raise "dynamic provider handshake timed out"
        end

      case {mode, index} do
        {:direct, 0} ->
          function_calls(conn, [{"discover", "tool_search", %{"query" => "read", "limit" => 2}}])

        {:nested, 0} ->
          custom_call(
            conn,
            "discover",
            "text(await tools.tool_search({query: 'read', limit: 2}));"
          )

        {:direct, 1} ->
          function_calls(conn, [
            {"file", @file_tool, %{"path" => "catalog.txt"}},
            {"mcp", ctx.mcp_name, %{"label" => "direct"}},
            {"shell", "exec_command",
             %{
               "cmd" => "printf 'run\\n' >> catalog-count.txt",
               "login" => false,
               "yield_time_ms" => 1000
             }}
          ])

        {:nested, 1} ->
          custom_call(conn, "code-start", nested_source(ctx))

        {:nested, 2} ->
          function_calls(conn, [
            {"code-resume", "wait", %{"cell_id" => delivery, "yield_time_ms" => 1000}}
          ])

        _ ->
          sse(conn, [
            %{"type" => "response.output_text.delta", "delta" => "Dynamic complete"},
            completed([])
          ])
      end
    end)
  end

  defp nested_source(ctx) do
    """
    text(await tools.synapsis__file_read({path: "catalog.txt"}));
    text(await tools[#{Jason.encode!(ctx.mcp_name)}]({label: "nested"}));
    text(await tools.exec_command({cmd: "printf 'run\\n' >> catalog-count.txt", login: false, yield_time_ms: 1000}));
    store("catalog-marker", "continued");
    yield "catalog-pause";
    text(load("catalog-marker"));
    text(await tools.clock__curr_time({}));
    """
  end

  defp replay(ctx, runtime, index, parts, uses, results) do
    monitor = Process.monitor(runtime.worker)
    assert :ok = DynamicSupervisor.stop_session(ctx.id)
    assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000
    SessionHarness.ensure_running!(ctx.id)
    [{fresh, _}] = Registry.lookup(Synapsis.Session.Registry, ctx.id)
    assert fresh != runtime.worker
    assert :ok = Worker.send_message(ctx.id, "Recall completed discovery")
    assert_receive {:dynamic_request, ^index, request, handler}, 15_000
    assert_wire_history(request, uses, results)
    send(handler, :deliver)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    assert tool_parts(ctx.id) == parts
    assert_durable_parts(ctx.id, uses, results)
    assert length(Agent.get(ctx.effects, & &1)) == 1
    assert File.read!(Path.join(ctx.root, "catalog-count.txt")) == "run\n"
  end

  defp setup_context(root, children? \\ false) do
    owner = self()
    effects = start_supervised!({Agent, fn -> [] end})
    fixture = Gaoxy.Test.open()

    Gaoxy.Test.stub(fixture, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      result =
        case request["method"] do
          "initialize" ->
            %{
              "protocolVersion" => request["params"]["protocolVersion"],
              "capabilities" => %{"tools" => %{}},
              "serverInfo" => %{"name" => "catalog-fixture", "version" => "1"}
            }

          "tools/list" ->
            %{
              "tools" => [
                %{
                  "name" => @raw,
                  "description" => "Read the selected local catalog fixture",
                  "annotations" => %{"readOnlyHint" => true},
                  "inputSchema" => %{
                    "type" => "object",
                    "properties" => %{"label" => %{"type" => "string"}},
                    "required" => ["label"],
                    "additionalProperties" => false
                  }
                }
              ]
            }

          "tools/call" ->
            params = request["params"]
            Agent.update(effects, &(&1 ++ [params]))
            send(owner, {:catalog_mcp_effect, params})

            %{
              "content" => [
                %{"type" => "text", "text" => "source " <> params["arguments"]["label"]}
              ],
              "structuredContent" => params["arguments"],
              "isError" => false
            }

          _ ->
            %{}
        end

      if Map.has_key?(request, "id") do
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
        )
      else
        Plug.Conn.resp(conn, 202, "")
      end
    end)

    for method <- ["GET", "DELETE"],
        do: Gaoxy.Test.stub(fixture, method, "/mcp", &Plug.Conn.resp(&1, 200, ""))

    assert {:ok, source} =
             Synapsis.MCPConfigs.create(%{
               name: "catalog-mcp-#{System.unique_integer([:positive])}",
               transport: "streamable_http",
               url: String.trim_trailing(Gaoxy.Test.url(fixture), "/")
             })

    source_pid = start_supervised!(Supervisor.child_spec({Server, source}, restart: :temporary))
    assert :ok = Server.await_ready(source_pid)

    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => children?, "memory_context" => false}
      )

    on_exit(fn ->
      SessionHarness.cleanup!(harness)
      Synapsis.MCPConfigs.delete(source)

      case Synapsis.Providers.get_by_name(harness.provider.name) do
        {:ok, provider} -> Synapsis.Providers.delete(provider.id)
        {:error, :not_found} -> :ok
      end
    end)

    mcp_name = "mcp::#{source.id}::#{@raw}"

    selection =
      @selected ++
        [@file_tool, @status, @summary, mcp_name] ++
        if(children?, do: ~w(spawn_agent wait_agent), else: [])

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(harness.agent_config, %{
               tools: selection,
               config:
                 Map.put(harness.agent_config.config, "deferred_tool_names", [
                   @file_tool,
                   mcp_name
                 ])
             })

    assert {:ok, provider} =
             Synapsis.Providers.create(%{
               name: harness.provider.name,
               type: "openai_responses",
               base_url: harness.provider.base_url,
               api_key_encrypted: "test-key"
             })

    assert {:ok, %{type: "openai_responses", provider_id: provider_id}} =
             Synapsis.Providers.runtime_config(harness.provider.name)

    assert provider_id == provider.id
    File.write!(Path.join(root, "catalog.txt"), "pinned catalog fixture\n")
    SessionHarness.subscribe!(harness.session.id)

    %{
      harness: harness,
      id: harness.session.id,
      root: root,
      mcp_name: mcp_name,
      effects: effects,
      selection: selection
    }
  end

  defp initial_runtime(id) do
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    {_, data} = :sys.get_state(worker)
    state = :sys.get_state(data.runtime_pid)

    %{
      worker: worker,
      adapter: data.runtime_pid,
      root: state.root,
      binding: state.binding,
      catalog: :sys.get_state(state.root).catalog,
      run_id: state.run_id,
      store: state.store
    }
  end

  defp operations(runtime, type) do
    assert {:ok, aggregate} = Synapsis.Runtime.Store.load(runtime.store.namespace, runtime.run_id)
    for {_, intent} <- aggregate.run.execution_intents, intent.type == type, do: intent.operation
  end

  defp wire_result(request, runtime, call_id) do
    # Public Conversation history is authoritative while its provider is active.
    # Convert through the same public host projection used for durable Parts.
    assert {:ok, messages} = ProviderMessages.to_host(Conversation.status(runtime.root).messages)

    [part] =
      for message <- messages,
          part = %ToolResult{} <- message.parts,
          part.tool_use_id == call_id,
          do: part

    output =
      Enum.find(
        request["input"],
        &(&1["type"] in ~w(custom_tool_call_output function_call_output) and
            &1["call_id"] == call_id)
      )

    assert output["output"] == part.content
    assert part.is_error == false
    part.projection["result"]
  end

  defp tool_parts(id),
    do:
      for(
        message <- Synapsis.Sessions.get_messages(id),
        part <- message.parts,
        match?(%ToolUse{}, part) or match?(%ToolResult{}, part),
        do: part
      )

  defp assert_part_round_trips(parts) do
    for part <- parts do
      assert {:ok, dump} = Synapsis.Part.dump(part)
      assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
    end
  end

  defp assert_durable_parts(id, uses, results) do
    assert {:ok, turns} = Store.list_turns(id)

    durable =
      for turn <- turns, part <- turn.parts, part[:type] in ~w(tool_use tool_result), do: part

    assert Enum.count(durable, &(&1[:type] == "tool_use")) == length(uses)
    assert Enum.count(durable, &(&1[:type] == "tool_result")) == length(results)

    for use <- uses do
      assert Enum.any?(
               durable,
               &(&1[:type] == "tool_use" and &1[:id] == use.tool_use_id and
                   &1[:name] == use.tool and &1[:input] == use.input)
             )
    end

    for result <- results do
      assert Enum.any?(
               durable,
               &(&1[:type] == "tool_result" and
                   &1[:tool_use_id] == result.tool_use_id and &1[:projection] == result.projection and
                   &1[:content] == result.content and &1[:is_error] == false)
             )
    end
  end

  defp assert_wire_history(request, uses, results) do
    for use <- uses do
      name = ToolName.encode(use.tool)

      if use.tool == "exec" do
        assert %{
                 "type" => "custom_tool_call",
                 "call_id" => use.tool_use_id,
                 "name" => name,
                 "input" => use.input
               } in request["input"]
      else
        assert Enum.any?(
                 request["input"],
                 &(&1["type"] == "function_call" and
                     &1["call_id"] == use.tool_use_id and &1["name"] == name and
                     Jason.decode!(&1["arguments"]) == use.input)
               )
      end
    end

    for {use, result} <- Enum.zip(uses, results) do
      type = if use.tool == "exec", do: "custom_tool_call_output", else: "function_call_output"
      expected = %{"type" => type, "call_id" => result.tool_use_id, "output" => result.content}
      assert expected in request["input"]

      assert Enum.find_index(
               request["input"],
               &(&1["call_id"] == use.tool_use_id and
                   &1["type"] in ~w(custom_tool_call function_call))
             ) <
               Enum.find_index(request["input"], &(&1 == expected))
    end
  end

  defp assert_os_reaped(pid) do
    path = "/proc/#{pid}"
    await_os_reaped(path, System.monotonic_time(:millisecond) + 2_000)
    assert File.exists?(path) == false
  end

  defp await_os_reaped(path, deadline) do
    if File.exists?(path) and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(10)
      await_os_reaped(path, deadline)
    end
  end

  defp function_calls(conn, calls) do
    items =
      for {id, name, args} <- calls,
          do: %{
            "type" => "function_call",
            "id" => id <> "-item",
            "call_id" => id,
            "name" => ToolName.encode(name),
            "arguments" => Jason.encode!(args)
          }

    events =
      for {item, index} <- Enum.with_index(items),
          event <- [
            %{
              "type" => "response.output_item.added",
              "output_index" => index,
              "item" => Map.put(item, "arguments", "")
            },
            %{
              "type" => "response.function_call_arguments.delta",
              "item_id" => item["id"],
              "delta" => item["arguments"]
            },
            %{"type" => "response.output_item.done", "output_index" => index, "item" => item}
          ],
          do: event

    sse(conn, events ++ [completed(items)])
  end

  defp custom_call(conn, id, raw) do
    item = %{
      "type" => "custom_tool_call",
      "id" => id <> "-item",
      "call_id" => id,
      "name" => "exec",
      "input" => raw
    }

    sse(conn, [
      %{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => Map.put(item, "input", "")
      },
      %{
        "type" => "response.custom_tool_call_input.delta",
        "item_id" => item["id"],
        "delta" => raw
      },
      %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
      completed([item])
    ])
  end

  defp completed(output),
    do: %{
      "type" => "response.completed",
      "response" => %{"status" => "completed", "output" => output}
    }

  defp sse(conn, events),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(
        200,
        Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n"))
      )
end
