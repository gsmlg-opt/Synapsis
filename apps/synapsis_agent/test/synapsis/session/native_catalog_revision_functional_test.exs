defmodule Synapsis.Session.NativeCatalogRevisionFunctionalTest do
  use ExUnit.Case, async: false

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
  @file_tool "synapsis::read"
  @status "synapsis::session_status"
  @summary "synapsis::session_summarize"
  @selected ~w(exec_command clock::curr_time exec wait)

  test "Worker pins a batch to one and executes unchanged host and MCP descriptors at two", %{
    tmp_dir: root
  } do
    ctx = setup_context(root)
    install_provider(ctx, :direct)
    runtime = publish_during_first_batch(ctx)

    {second, handler} = request(ctx, runtime, 1, 2)
    assert first_batch_results(second)
    send(handler, :deliver)

    {following, handler} = request(ctx, runtime, 2, 2)

    assert_receive {:catalog_mcp_effect,
                    %{"name" => "read", "arguments" => %{"label" => "direct"}}},
                   5_000

    send(handler, :deliver)
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000

    parts = tool_parts(ctx.id)
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))
    assert Enum.map(uses, & &1.tool_use_id) == ~w(gate old-file new-file status summary mcp)
    assert Enum.all?(results, &(&1.is_error == false))
    assert result(results, "new-file").content =~ "pinned catalog fixture"

    live = result(results, "status").projection["result"]["structured"]
    assert live["source"] == "live"
    assert live["session"]["id"] == ctx.id
    assert live["runtime"]["active"] == true

    summary = result(results, "summary").projection["result"]["structured"]
    assert summary["source"] == "live_session"
    assert summary["extraction"] == "heuristic"
    assert summary["message_count"] > 0
    assert result(results, "mcp").projection["result"]["structured"] == %{"label" => "direct"}

    operations = operations(runtime, :tool)

    assert Enum.sort(Enum.map(operations, & &1.tool_call_id)) ==
             Enum.sort(~w(gate old-file new-file status summary mcp))

    assert_operations(runtime, operations, ~w(gate old-file))
    assert_wire_history(following, uses, results)
    assert_durable_parts(ctx.id, uses, results)
    assert_part_round_trips(parts)
    replay(ctx, runtime, 3, parts, uses, results, 1)
  end

  test "Worker Code Mode keeps native revision two across nested tools, yield, wait and replay",
       %{
         tmp_dir: root
       } do
    ctx = setup_context(root)
    install_provider(ctx, :nested)
    runtime = publish_during_first_batch(ctx)

    {second, handler} = request(ctx, runtime, 1, 2)
    assert first_batch_results(second)
    send(handler, :deliver)

    {yielded_request, handler} = request(ctx, runtime, 2, 2)

    assert_receive {:catalog_mcp_effect,
                    %{"name" => "read", "arguments" => %{"label" => "nested"}}},
                   5_000

    yielded = wire_result(yielded_request, runtime, "code-start")
    assert yielded["status"] == "yielded"
    assert yielded["value"] == "catalog-pause"
    assert Enum.any?(yielded["output"], &String.contains?(&1["text"], "pinned catalog fixture"))
    assert Enum.any?(yielded["output"], &String.contains?(&1["text"], "source nested"))
    assert Enum.any?(yielded["output"], &String.contains?(&1["text"], "current_time"))

    handle = %{
      resource_id: yielded["cell_id"],
      owner_id: runtime.binding.owner_id,
      incarnation: runtime.binding.incarnation,
      kind: :continuation
    }

    assert {:ok, deno} =
             ResourceRegistry.fetch(runtime.binding.resource_registry, handle, handle.owner_id)

    assert Process.alive?(deno)
    assert {:ok, os_identity} = NativeCodeMode.Worker.os_identity(deno)
    assert File.exists?("/proc/#{os_identity.pid}")
    monitor = Process.monitor(deno)
    send(handler, {:deliver, yielded["cell_id"]})

    {following, handler} = request(ctx, runtime, 3, 2)
    resumed = wire_result(following, runtime, "code-resume")
    assert resumed["status"] == "completed"

    assert [%{"text" => "continued"}, %{"text" => clock}, %{"text" => "after-yield"}] =
             resumed["output"]

    assert clock =~ "current_time"
    send(handler, :deliver)
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert_receive {:DOWN, ^monitor, :process, ^deno, _}, 5_000
    assert_os_reaped(os_identity.pid)
    assert %{phase: :idle} = Session.status(runtime.binding.session)

    parts = tool_parts(ctx.id)
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))
    assert Enum.map(uses, & &1.tool_use_id) == ~w(gate old-file code-start code-resume)
    assert Enum.map(uses, & &1.tool) == ["exec_command", @file_tool, "exec", "wait"]
    assert Enum.find(uses, &(&1.tool == "exec")).input == nested_source(ctx)
    assert Enum.all?(results, &(&1.is_error == false))

    operations = operations(runtime, :tool)

    assert Enum.sort(Enum.map(operations, & &1.tool_name)) ==
             Enum.sort([
               "exec_command",
               @file_tool,
               "exec",
               @file_tool,
               ctx.mcp_name,
               "clock::curr_time",
               "wait",
               "clock::curr_time"
             ])

    assert_operations(runtime, operations, ~w(gate old-file))
    [outer] = Enum.filter(operations, &(&1.tool_name == "exec"))
    [wait] = Enum.filter(operations, &(&1.tool_name == "wait"))
    nested = Enum.filter(operations, &(&1.invocation_id != &1.enclosing_invocation_id))
    assert length(nested) == 4

    assert Enum.all?(
             nested,
             &(&1.enclosing_invocation_id in [outer.invocation_id, wait.invocation_id])
           )

    assert_wire_history(yielded_request, Enum.take(uses, 3), Enum.take(results, 3))
    assert_wire_history(following, uses, results)
    assert_durable_parts(ctx.id, uses, results)
    assert_part_round_trips(parts)
    replay(ctx, runtime, 4, parts, uses, results, 1)
  end

  defp setup_context(root) do
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
                  "name" => "read",
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
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn ->
      SessionHarness.cleanup!(harness)
      Synapsis.MCPConfigs.delete(source)

      case Synapsis.Providers.get_by_name(harness.provider.name) do
        {:ok, provider} -> Synapsis.Providers.delete(provider.id)
        {:error, :not_found} -> :ok
      end
    end)

    mcp_name = "mcp::#{source.id}::read"
    selection = @selected ++ [@file_tool, @status, @summary, mcp_name]
    assert {:ok, _} = Synapsis.AgentConfigs.update(harness.agent_config, %{tools: selection})

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

      if index == 0, do: send(owner, {:catalog_initial_runtime, initial_runtime(ctx.id)})
      send(owner, {:catalog_request, index, request, self()})

      delivery =
        receive do
          :deliver -> :deliver
          {:deliver, cell_id} -> cell_id
        after
          10_000 -> raise "catalog provider handshake timed out"
        end

      case {mode, index} do
        {_, 0} ->
          function_calls(conn, [
            {"gate", "exec_command",
             %{"cmd" => gate_command(), "login" => false, "yield_time_ms" => 30_000}},
            {"old-file", @file_tool, %{"path" => "catalog.txt"}}
          ])

        {:direct, 1} ->
          function_calls(conn, [
            {"new-file", @file_tool, %{"path" => "catalog.txt"}},
            {"status", @status, %{"source" => "live"}},
            {"summary", @summary, %{"scope" => "recent", "use_llm" => false}},
            {"mcp", ctx.mcp_name, %{"label" => "direct"}}
          ])

        {:nested, 1} ->
          custom_call(conn, "code-start", nested_source(ctx))

        {:nested, 2} ->
          function_calls(conn, [
            {"code-resume", "wait", %{"cell_id" => delivery, "yield_time_ms" => 1000}}
          ])

        _ ->
          sse(conn, [
            %{"type" => "response.output_text.delta", "delta" => "Catalog run complete"},
            completed([])
          ])
      end
    end)
  end

  defp publish_during_first_batch(ctx) do
    SessionHarness.ensure_running!(ctx.id)

    assert :ok =
             Worker.send_message(
               ctx.id,
               "Read the catalog fixture and remember this ordinary turn"
             )

    assert_receive {:catalog_initial_runtime, runtime}, 5_000
    {first, handler} = request(ctx, runtime, 0, 1)

    assert Enum.sort(Enum.map(first["tools"], & &1["name"])) ==
             Enum.sort(Enum.map(ctx.selection, &ToolName.encode/1))

    assert Enum.sort(Map.keys(runtime.catalog.registry.tools)) == Enum.sort(ctx.selection)

    assert runtime.catalog.revision == 1

    for name <- [@file_tool, @status, @summary, ctx.mcp_name] do
      assert runtime.catalog.registry.tools[name].backend_context.catalog_revision == 1
    end

    assert runtime.catalog.registry.tools["exec"].backend_context.session_binding ==
             runtime.binding

    assert runtime.catalog.registry.tools["wait"].backend_context.session_binding ==
             runtime.binding

    send(handler, :deliver)
    assert_file(Path.join(ctx.root, "catalog-started"))

    assert {:ok, %{status: :staged, catalog_revision: 2}} =
             Conversation.stage_catalog(runtime.root, %{
               publication_id: Ecto.UUID.generate(),
               run_id: runtime.run_id,
               incarnation: runtime.binding.run_incarnation,
               expected_revision: 1,
               schema_admission: :strict,
               catalog: Map.put(runtime.catalog, :revision, 2)
             })

    # Release the real shell immediately after the public native staging receipt.
    File.write!(Path.join(ctx.root, "catalog-release"), "release")
    assert runtime.catalog.revision == 1
    assert runtime.catalog.registry.tools[@file_tool].backend_context.catalog_revision == 1
    Map.put(runtime, :wire_tools, first["tools"])
  end

  defp request(_ctx, runtime, index, revision) do
    assert_receive {:catalog_request, ^index, request, handler}, 10_000
    assert request["model"] == "characterization-model"
    if Map.has_key?(runtime, :wire_tools), do: assert(request["tools"] == runtime.wire_tools)
    providers = operations(runtime, :provider)
    assert Enum.count(providers, &(&1.catalog_revision == revision)) >= 1
    assert Enum.all?(providers, &(&1.run_id == runtime.run_id))
    assert Conversation.status(runtime.root).catalog_revision == revision
    {request, handler}
  end

  # This fixture read only identifies the actual Worker-owned root and captures
  # its initially admitted catalog. Publication and all execution use public APIs.
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

  defp assert_operations(runtime, operations, old_ids) do
    assert length(operations) > length(old_ids)

    for operation <- operations do
      assert operation.run_id == runtime.run_id
      assert operation.incarnation == runtime.binding.run_incarnation
      assert operation.catalog_revision == if(operation.tool_call_id in old_ids, do: 1, else: 2)
      descriptor = runtime.catalog.registry.tools[operation.tool_name]
      assert operation.tool_revision == descriptor.tool_revision
    end

    for name <- [@file_tool, @status, @summary] do
      assert runtime.catalog.registry.tools[name].backend_context.catalog_revision == 1
    end
  end

  defp replay(ctx, runtime, index, parts, uses, results, mcp_count) do
    assert File.read!(Path.join(ctx.root, "catalog-count.txt")) == "run\n"
    assert length(Agent.get(ctx.effects, & &1)) == mcp_count
    assert %{phase: :idle} = Session.status(runtime.binding.session)

    monitors =
      for pid <- [
            runtime.worker,
            runtime.adapter,
            runtime.binding.session,
            runtime.binding.resource_registry
          ],
          do: {pid, Process.monitor(pid)}

    assert :ok = DynamicSupervisor.stop_session(ctx.id)

    for {pid, monitor} <- monitors,
        do: assert_receive({:DOWN, ^monitor, :process, ^pid, _}, 5_000)

    SessionHarness.ensure_running!(ctx.id)
    [{new_worker, _}] = Registry.lookup(Synapsis.Session.Registry, ctx.id)
    assert new_worker != runtime.worker
    assert :ok = Worker.send_message(ctx.id, "Recall the completed catalog turn")
    assert_receive {:catalog_request, ^index, request, handler}, 10_000
    assert_wire_history(request, uses, results)
    send(handler, :deliver)
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert tool_parts(ctx.id) == parts
    assert_durable_parts(ctx.id, uses, results)
    assert File.read!(Path.join(ctx.root, "catalog-count.txt")) == "run\n"
    assert length(Agent.get(ctx.effects, & &1)) == mcp_count
    assert length(Agent.get(ctx.harness.counter, & &1.provider_requests)) == index + 1
    assert :ok = DynamicSupervisor.stop_session(ctx.id)
  end

  defp gate_command do
    "printf 'run\\n' >> catalog-count.txt; printf ready > catalog-started; " <>
      "for i in $(seq 1 1000); do if [ -f catalog-release ]; then break; fi; sleep 0.01; done; printf released"
  end

  defp nested_source(ctx) do
    """
    text(await tools.synapsis__read({path: "catalog.txt"}));
    text(await tools[#{Jason.encode!(ctx.mcp_name)}]({label: "nested"}));
    text(await tools.clock__curr_time({}));
    store("catalog-marker", "continued");
    yield "catalog-pause";
    text(load("catalog-marker"));
    text(await tools.clock__curr_time({}));
    text("after-yield");
    """
  end

  defp first_batch_results(request) do
    assert Enum.any?(
             request["input"],
             &(&1["type"] == "function_call_output" and
                 &1["call_id"] == "gate" and String.contains?(&1["output"], "released"))
           )

    assert Enum.any?(
             request["input"],
             &(&1["type"] == "function_call_output" and
                 &1["call_id"] == "old-file" and
                 String.contains?(&1["output"], "pinned catalog fixture"))
           )
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

  defp result(results, id), do: Enum.find(results, &(&1.tool_use_id == id))

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

  defp assert_file(path), do: await_file(path, System.monotonic_time(:millisecond) + 5_000)

  defp await_file(path, deadline) do
    cond do
      File.exists?(path) ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(10)
        await_file(path, deadline)

      true ->
        flunk("native shell did not create its start marker")
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
