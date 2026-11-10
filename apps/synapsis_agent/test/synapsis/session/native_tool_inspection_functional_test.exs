defmodule Synapsis.Session.NativeToolInspectionFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Backplane.AgentRuntime.Conversation
  alias Backplane.AgentRuntime.Codex.Session
  alias Backplane.McpProtocol.Client
  alias Synapsis.Agent.Runtime.ProviderMessages
  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Agent.Tools.{MCP, ToolInspection}
  alias Synapsis.MCP.Server
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}
  alias Synapsis.{AgentConfigs, Providers}

  @moduletag :tmp_dir
  @moduletag timeout: 90_000
  @version "2026-07-28"
  @inspect "synapsis::tool_describe"
  @raw "notes.lookup"
  @description "Read metadata inspection notes with their complete nested contract.\n雪 😀 — preserve every field."
  @instructions """
  Notes metadata inspection fixture — 雪 😀.
  The server advertises this complete multiline instruction document as ordinary metadata.
  Preserve Unicode, blank lines, punctuation, and every repeated line exactly.

  01: 查询 notes.lookup，保持 operation、document 和 labels 原样。😀
  02: 查询 notes.lookup，保持 operation、document 和 labels 原样。😀
  03: 查询 notes.lookup，保持 operation、document 和 labels 原样。😀
  04: 查询 notes.lookup，保持 operation、document 和 labels 原样。😀
  05: 查询 notes.lookup，保持 operation、document 和 labels 原样。😀
  06: 查询 notes.lookup，保持 operation、document 和 labels 原样。😀
  07: 查询 notes.lookup，保持 operation、document 和 labels 原样。😀
  08: 查询 notes.lookup，保持 operation、document 和 labels 原样。😀
  Final line: complete available instructions, not a description excerpt. 完毕。
  """
  @schema %{
    "type" => "object",
    "description" => "Complete metadata inspection input contract",
    "properties" => %{
      "operation" => %{"type" => "string", "enum" => ["lookup", "read"]},
      "document" => %{
        "type" => "object",
        "properties" => %{
          "title" => %{"type" => "string", "minLength" => 1, "description" => "原始标题"},
          "labels" => %{
            "type" => "array",
            "minItems" => 1,
            "items" => %{
              "type" => "object",
              "properties" => %{
                "kind" => %{"type" => "string", "enum" => ["primary", "secondary"]},
                "weight" => %{"type" => "number", "minimum" => 0, "maximum" => 1}
              },
              "required" => ["kind", "weight"],
              "additionalProperties" => false
            }
          }
        },
        "required" => ["title", "labels"],
        "additionalProperties" => false
      }
    },
    "required" => ["operation", "document"],
    "additionalProperties" => false
  }
  @output_schema %{
    "type" => "object",
    "description" => "Complete metadata inspection output contract — 雪",
    "properties" => %{
      "ok" => %{"type" => "boolean"},
      "operation" => %{"type" => "string", "description" => "Public schema property"},
      "document" => %{
        "type" => "object",
        "properties" => %{
          "title" => %{"type" => "string"},
          "labels" => %{"type" => "array", "items" => %{"type" => "string"}}
        },
        "required" => ["title", "labels"],
        "additionalProperties" => false
      }
    },
    "required" => ["ok", "document"],
    "additionalProperties" => false
  }
  @input %{
    "operation" => "lookup",
    "document" => %{
      "title" => "Published 雪",
      "labels" => [
        %{"kind" => "secondary", "weight" => 0.25},
        %{"kind" => "primary", "weight" => 0.75}
      ]
    }
  }
  @result %{"ok" => true, "document" => %{"title" => "Published 雪", "labels" => ["雪", "😀"]}}
  @exec_description "Execute isolated JavaScript with tools, ALL_TOOLS, text/image/audio, generatedImage, store/load, notify, exit and yield_control. A first-line // @exec: JSON pragma sets yield_time_ms and max_output_tokens. Wait only on returned cell_id; each wait returns new output and uses current admitted authority."
  @grammar """
  start: pragma_source | plain_source
  pragma_source: PRAGMA_LINE NEWLINE SOURCE
  plain_source: SOURCE

  PRAGMA_LINE: /[ \\t]*\\/\\/ @exec:[^\\r\\n]*/
  NEWLINE: /\\r?\\n/
  SOURCE: /[\\s\\S]+/
  """
  @exec_format %{"type" => "grammar", "syntax" => "lark", "definition" => @grammar}

  test "Worker inspection preserves selected deferred metadata through publication and durable replay",
       %{tmp_dir: root} do
    ctx = setup_context(root)
    install_provider(ctx)
    SessionHarness.subscribe!(ctx.id)
    SessionHarness.ensure_running!(ctx.id)

    assert :ok =
             Worker.send_message(
               ctx.id,
               "Inspect the selected tools before publishing and using notes"
             )

    assert_receive {:inspection_request, 0, initial, handler}, 15_000
    ctx = capture_run_source(ctx)
    runtime = runtime(ctx.id)

    issued =
      :sys.get_state(runtime.adapter).tool_contexts[{runtime.run_id, 1}].snapshot.issued_descriptors

    assert names(initial) ==
             Enum.sort(Enum.map([@inspect, "tool_search", "wait"], &ToolName.encode/1))

    assert Conversation.status(runtime.root).catalog_revision == 1
    assert issued[@inspect].backend == ToolInspection
    assert issued[ctx.mcp_name].backend == MCP
    assert issued[ctx.mcp_name].schema == @schema
    assert issued[ctx.mcp_name].description == @description
    assert issued[ctx.mcp_name].codex_output_schema == @output_schema
    assert issued[ctx.mcp_name].tool_revision == ctx.source_snapshot.generation
    assert issued[ctx.mcp_name].backend_context.source === ctx.source_snapshot
    assert issued["exec"].codex_input_kind == :custom
    assert json(issued["exec"].codex_format) == @exec_format
    assert issued["exec"].description == @exec_description
    assert Agent.get(ctx.effects, & &1) == 0
    send(handler, :deliver)

    assert_receive {:inspection_request, 1, inspected, handler}, 15_000
    before = assert_inspection(inspected, runtime, "describe-before", mcp_document(ctx))
    assert names(inspected) == names(initial)
    assert Conversation.status(runtime.root).catalog_revision == 1
    assert Agent.get(ctx.effects, & &1) == 0
    send(handler, :deliver)

    assert_receive {:inspection_request, 2, grammar, handler}, 15_000
    custom = assert_inspection(grammar, runtime, "describe-grammar", exec_document())
    assert names(grammar) == names(initial)
    assert Conversation.status(runtime.root).catalog_revision == 1
    assert Agent.get(ctx.effects, & &1) == 0
    assert Enum.map(operations(runtime, :tool), & &1.tool_name) == [@inspect, @inspect]
    send(handler, :deliver)

    assert_receive {:inspection_request, 3, published, handler}, 15_000

    assert names(published) ==
             Enum.sort(Enum.map(ctx.selection ++ ["tool_search"], &ToolName.encode/1))

    assert Conversation.status(runtime.root).catalog_revision == 2
    assert output(published, "discover")["output"] =~ "staged"
    current = :sys.get_state(runtime.root).catalog

    for name <- [@inspect, ctx.mcp_name, "exec", "wait"] do
      assert current.registry.tools[name] === issued[name]
    end

    assert declaration(published, ctx.mcp_name) == %{
             "type" => "function",
             "name" => ToolName.encode(ctx.mcp_name),
             "description" => @description,
             "parameters" => @schema
           }

    assert declaration(published, "exec") == %{
             "type" => "custom",
             "name" => "exec",
             "description" => @exec_description,
             "format" => @exec_format
           }

    assert {:ok, aggregate} = Synapsis.Runtime.Store.load(runtime.store.namespace, runtime.run_id)

    assert aggregate.run.context.conversation.catalog_publication ==
             Conversation.status(runtime.root).catalog_publication

    assert :sys.get_state(runtime.binding.session).active.catalog_revision == 2
    assert Agent.get(ctx.effects, & &1) == 0
    send(handler, :deliver)

    assert_receive {:inspection_request, 4, reinspected, handler}, 15_000

    after_publication =
      assert_inspection(reinspected, runtime, "describe-after", mcp_document(ctx))

    assert after_publication.content == before.content
    assert names(reinspected) == names(published)
    assert Conversation.status(runtime.root).catalog_revision == 2
    assert :sys.get_state(runtime.root).catalog.registry.tools[@inspect] === issued[@inspect]
    assert Agent.get(ctx.effects, & &1) == 0

    assert Map.new(operations(runtime, :tool), &{&1.tool_call_id, &1.catalog_revision}) == %{
             "describe-before" => 1,
             "describe-grammar" => 1,
             "discover" => 1,
             "describe-after" => 2
           }

    send(handler, :deliver)

    assert_receive {:inspection_mcp_call, %{"name" => @raw, "arguments" => @input} = params},
                   15_000

    assert Map.drop(params, ["_meta"]) == %{"name" => @raw, "arguments" => @input}

    assert_receive {:inspection_request, 5, consumed, handler}, 15_000

    assert {:ok, host_messages} =
             ProviderMessages.to_host(Conversation.status(runtime.root).messages)

    results = for message <- host_messages, part = %ToolResult{} <- message.parts, do: part
    target = Enum.find(results, &(&1.tool_use_id == "notes-once"))
    assert target.is_error == false
    assert target.projection["result"]["structured"] == @result
    assert output(consumed, "notes-once")["output"] == target.content
    assert Agent.get(ctx.effects, & &1) == 1
    assert Conversation.status(runtime.root).catalog_revision == 2

    tool_operations = operations(runtime, :tool)
    assert length(tool_operations) == 5
    assert Enum.count(tool_operations, &(&1.tool_name == ctx.mcp_name)) == 1
    assert Enum.all?(tool_operations, &(&1.tool_name != "exec"))
    target_operation = Enum.find(tool_operations, &(&1.tool_call_id == "notes-once"))
    assert target_operation.catalog_revision == 2
    assert target_operation.backend == MCP
    assert target_operation.tool_revision == ctx.source_snapshot.generation
    send(handler, :deliver)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    assert %{phase: :idle} = Session.status(runtime.binding.session)

    parts = tool_parts(ctx.id)
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))

    assert Enum.map(uses, &{&1.tool_use_id, &1.tool}) == [
             {"describe-before", @inspect},
             {"describe-grammar", @inspect},
             {"discover", "tool_search"},
             {"describe-after", @inspect},
             {"notes-once", ctx.mcp_name}
           ]

    assert before.content == after_publication.content
    assert Jason.decode!(custom.content) == exec_document()

    for part <- parts do
      assert {:ok, dump} = Synapsis.Part.dump(part)
      assert {:ok, ^part} = dump |> json() |> Synapsis.Part.load()
    end

    assert_durable_results(ctx.id, results)
    assert_wire_history(consumed, uses, results)

    assert :ok =
             Worker.send_message(
               ctx.id,
               "Recall the completed inspection without executing tools"
             )

    assert_receive {:inspection_request, 6, second_turn, handler}, 15_000
    assert_wire_history(second_turn, uses, results)
    assert output(second_turn, "describe-before")["output"] == before.content
    assert output(second_turn, "describe-after")["output"] == before.content
    assert Agent.get(ctx.effects, & &1) == 1
    send(handler, :deliver)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    assert tool_parts(ctx.id) == parts
    assert_durable_results(ctx.id, results)

    replay(ctx, parts, uses, results)
    assert AgentConfigs.get(ctx.harness.agent_config.id).tools == ctx.selection
    assert length(Agent.get(ctx.harness.counter, & &1.provider_requests)) == 8
  end

  test "Worker inspection retains legacy source receipt and complete schemas through durable replay",
       %{tmp_dir: root} do
    ctx = setup_context(root, :legacy)
    install_legacy_provider(ctx)
    SessionHarness.subscribe!(ctx.id)
    SessionHarness.ensure_running!(ctx.id)

    assert :ok =
             Worker.send_message(ctx.id, "Inspect the selected legacy source before using notes")

    assert_receive {:inspection_request, 0, initial, handler}, 15_000
    ctx = capture_run_source(ctx)
    runtime = runtime(ctx.id)

    issued =
      :sys.get_state(runtime.adapter).tool_contexts[{runtime.run_id, 1}].snapshot.issued_descriptors

    assert names(initial) == Enum.sort(Enum.map(ctx.selection, &ToolName.encode/1))
    assert Conversation.status(runtime.root).catalog_revision == 1
    assert issued[@inspect].backend == ToolInspection
    assert issued[ctx.mcp_name].backend == MCP
    assert issued[ctx.mcp_name].schema == @schema
    assert issued[ctx.mcp_name].codex_output_schema == @output_schema
    assert issued[ctx.mcp_name].backend_context.source === ctx.source_snapshot

    assert declaration(initial, ctx.mcp_name) == %{
             "type" => "function",
             "name" => ToolName.encode(ctx.mcp_name),
             "description" => @description,
             "parameters" => @schema
           }

    assert Agent.get(ctx.effects, & &1) == 0
    send(handler, :deliver)

    assert_receive {:inspection_request, 1, inspected, handler}, 15_000

    inspection =
      assert_inspection(inspected, runtime, "legacy-describe", legacy_mcp_document(ctx))

    assert names(inspected) == names(initial)
    assert Conversation.status(runtime.root).catalog_revision == 1

    assert :sys.get_state(runtime.root).catalog.registry.tools[ctx.mcp_name] ===
             issued[ctx.mcp_name]

    assert Agent.get(ctx.effects, & &1) == 0
    assert Enum.map(operations(runtime, :tool), & &1.tool_name) == [@inspect]
    send(handler, :deliver)

    assert_receive {:inspection_mcp_call, %{"name" => @raw, "arguments" => @input} = params},
                   15_000

    assert Map.drop(params, ["_meta"]) == %{"name" => @raw, "arguments" => @input}
    assert_receive {:inspection_request, 2, consumed, handler}, 15_000
    assert {:ok, messages} = ProviderMessages.to_host(Conversation.status(runtime.root).messages)
    results = for message <- messages, part = %ToolResult{} <- message.parts, do: part
    target = Enum.find(results, &(&1.tool_use_id == "legacy-notes-once"))
    assert target.is_error == false
    assert target.projection["result"]["structured"] == @result
    assert output(consumed, "legacy-notes-once")["output"] == target.content
    assert Agent.get(ctx.effects, & &1) == 1

    assert Map.new(operations(runtime, :tool), &{&1.tool_call_id, &1.catalog_revision}) == %{
             "legacy-describe" => 1,
             "legacy-notes-once" => 1
           }

    send(handler, :deliver)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    assert %{phase: :idle} = Session.status(runtime.binding.session)
    parts = tool_parts(ctx.id)
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))

    assert Enum.map(uses, &{&1.tool_use_id, &1.tool}) == [
             {"legacy-describe", @inspect},
             {"legacy-notes-once", ctx.mcp_name}
           ]

    for part <- parts do
      assert {:ok, dump} = Synapsis.Part.dump(part)
      assert {:ok, ^part} = dump |> json() |> Synapsis.Part.load()
    end

    assert_durable_results(ctx.id, results)
    assert_wire_history(consumed, uses, results)
    assert :ok = Worker.send_message(ctx.id, "Recall the completed legacy inspection")
    assert_receive {:inspection_request, 3, second_turn, handler}, 15_000
    assert_wire_history(second_turn, uses, results)
    assert output(second_turn, "legacy-describe")["output"] == inspection.content
    assert Agent.get(ctx.effects, & &1) == 1
    send(handler, :deliver)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    assert tool_parts(ctx.id) == parts
    assert_durable_results(ctx.id, results)

    replay(ctx, parts, uses, results, 4)
    assert AgentConfigs.get(ctx.harness.agent_config.id).tools == ctx.selection
    assert length(Agent.get(ctx.harness.counter, & &1.provider_requests)) == 5
  end

  defp capture_run_source(ctx) do
    initial = ctx.source_snapshot
    assert {:ok, current} = Server.runtime_snapshot(initial.server_pid)
    assert current.source_id === initial.source_id
    assert current.server_pid === initial.server_pid
    assert current.tools === initial.tools
    assert current.generation == initial.generation + 1
    %{ctx | source_snapshot: current}
  end

  defp setup_context(root), do: setup_context(root, :modern)

  defp setup_context(root, mode) do
    owner = self()
    effects = start_supervised!({Agent, fn -> 0 end})
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)

    Gaoxy.Test.stub(fixture, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      if Map.has_key?(request, "id") do
        result =
          case request["method"] do
            "initialize" ->
              send(owner, {:inspection_mcp_initialize, request["params"]})

              %{
                "protocolVersion" => request["params"]["protocolVersion"],
                "capabilities" => %{"tools" => %{}},
                "serverInfo" => %{"name" => "legacy-inspection-fixture", "version" => "1"},
                "instructions" => @instructions
              }

            "server/discover" ->
              send(
                owner,
                {:inspection_mcp_discovery, request["params"], Map.new(conn.req_headers)}
              )

              %{
                "resultType" => "complete",
                "supportedVersions" => [@version],
                "capabilities" => %{"tools" => %{}},
                "instructions" => @instructions,
                "ttlMs" => 0,
                "cacheScope" => "private"
              }

            "tools/list" ->
              %{
                "resultType" => "complete",
                "tools" => [
                  %{
                    "name" => @raw,
                    "description" => @description,
                    "annotations" => %{"readOnlyHint" => true},
                    "inputSchema" => @schema,
                    "outputSchema" => @output_schema
                  }
                ]
              }

            "tools/call" ->
              Agent.update(effects, &(&1 + 1))
              send(owner, {:inspection_mcp_call, request["params"]})

              %{
                "resultType" => "complete",
                "content" => [%{"type" => "text", "text" => "Notes consumed once — 雪 😀"}],
                "structuredContent" => @result,
                "isError" => false
              }
          end

        json_response(conn, %{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
      else
        Plug.Conn.resp(conn, 202, "")
      end
    end)

    Gaoxy.Test.stub(fixture, "GET", "/mcp", &Plug.Conn.resp(&1, 405, ""))
    Gaoxy.Test.stub(fixture, "DELETE", "/mcp", &Plug.Conn.resp(&1, 204, ""))

    assert {:ok, source} =
             Synapsis.MCPConfigs.create(%{
               name: "inspection-mcp-#{System.unique_integer([:positive])}",
               transport: "streamable_http",
               url: String.trim_trailing(Gaoxy.Test.url(fixture), "/"),
               config: if(mode == :legacy, do: %{}, else: %{"protocol_version" => @version})
             })

    on_exit(fn -> Synapsis.MCPConfigs.delete(source) end)
    source_pid = start_supervised!(Supervisor.child_spec({Server, source}, restart: :temporary))
    assert :ok = Server.await_ready(source_pid)
    info = Client.get_protocol_info(:sys.get_state(source_pid).client, timeout: 1_000)

    case mode do
      :modern ->
        assert_receive {:inspection_mcp_discovery, discovery, headers}, 3_000
        assert discovery["_meta"]["io.modelcontextprotocol/protocolVersion"] == @version
        assert headers["mcp-method"] == "server/discover"
        assert byte_size(@instructions) > 512
        assert info.era == :modern
        assert info.protocol_version == @version
        assert info.discovery["instructions"] == @instructions

      :legacy ->
        assert_receive {:inspection_mcp_initialize, initialize}, 3_000
        assert initialize["protocolVersion"] == "2025-06-18"
        assert info.era == :legacy
        assert info.protocol_version == "2025-06-18"
        assert info.discovery == nil
        assert source.config == %{}
    end

    assert {:ok, source_snapshot} = Server.runtime_snapshot(source_pid)
    assert source_snapshot.generation == 1
    assert [tool] = source_snapshot.tools
    assert tool.parameters == @schema
    assert tool.output_schema == @output_schema

    case mode do
      :modern ->
        assert tool.source_metadata == %{
                 server_name: source.name,
                 instructions_status: "available",
                 instructions: @instructions
               }

      :legacy ->
        assert tool.source_metadata == %{
                 server_name: source.name,
                 instructions_status: "not_retained_legacy"
               }
    end

    h =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn ->
      SessionHarness.cleanup!(h)

      case Providers.get_by_name(h.provider.name) do
        {:ok, provider} -> Providers.delete(provider.id)
        {:error, :not_found} -> :ok
      end
    end)

    assert {:ok, _} =
             Providers.create(%{
               name: h.provider.name,
               type: "openai_responses",
               base_url: h.provider.base_url,
               api_key_encrypted: "inspection-fixture"
             })

    mcp_name = "mcp::#{source.id}::#{@raw}"

    {selection, config} =
      case mode do
        :modern ->
          {[@inspect, mcp_name, "exec", "wait"],
           Map.put(h.agent_config.config, "deferred_tool_names", [mcp_name, "exec"])}

        :legacy ->
          {[@inspect, mcp_name], h.agent_config.config}
      end

    assert {:ok, _} = AgentConfigs.update(h.agent_config, %{tools: selection, config: config})

    %{
      harness: h,
      id: h.session.id,
      mcp_name: mcp_name,
      selection: selection,
      effects: effects,
      source: source,
      source_snapshot: source_snapshot
    }
  end

  defp install_provider(ctx) do
    owner = self()

    Gaoxy.Test.stub(ctx.harness.provider.fixture, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      index =
        Agent.get_and_update(ctx.harness.counter, fn state ->
          {length(state.provider_requests),
           %{state | provider_requests: state.provider_requests ++ [request]}}
        end)

      send(owner, {:inspection_request, index, request, self()})

      receive do
        :deliver -> :ok
      after
        15_000 -> raise "inspection provider handshake timed out"
      end

      case index do
        0 ->
          calls(conn, [{"describe-before", @inspect, %{"tool_name" => ctx.mcp_name}}])

        1 ->
          calls(conn, [{"describe-grammar", @inspect, %{"tool_name" => "exec"}}])

        2 ->
          calls(conn, [
            {"discover", "tool_search",
             %{"query" => "metadata inspection JavaScript", "limit" => 8}}
          ])

        3 ->
          calls(conn, [{"describe-after", @inspect, %{"tool_name" => ctx.mcp_name}}])

        4 ->
          calls(conn, [{"notes-once", ctx.mcp_name, @input}])

        index when index in [5, 6, 7] ->
          sse(conn, [
            %{"type" => "response.output_text.delta", "delta" => "Inspection complete — 雪 😀"},
            completed([])
          ])
      end
    end)
  end

  defp install_legacy_provider(ctx) do
    owner = self()

    Gaoxy.Test.stub(ctx.harness.provider.fixture, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      index =
        Agent.get_and_update(ctx.harness.counter, fn state ->
          {length(state.provider_requests),
           %{state | provider_requests: state.provider_requests ++ [request]}}
        end)

      send(owner, {:inspection_request, index, request, self()})

      receive do
        :deliver -> :ok
      after
        15_000 -> raise "legacy inspection provider handshake timed out"
      end

      case index do
        0 ->
          calls(conn, [{"legacy-describe", @inspect, %{"tool_name" => ctx.mcp_name}}])

        1 ->
          calls(conn, [{"legacy-notes-once", ctx.mcp_name, @input}])

        index when index in [2, 3, 4] ->
          sse(conn, [
            %{
              "type" => "response.output_text.delta",
              "delta" => "Legacy inspection complete — 雪 😀"
            },
            completed([])
          ])
      end
    end)
  end

  defp mcp_document(ctx) do
    %{
      "tool_name" => ctx.mcp_name,
      "tool_revision" => ctx.source_snapshot.generation,
      "description" => @description,
      "input_kind" => "function",
      "schema" => @schema,
      "output_schema" => @output_schema,
      "source" => %{
        "kind" => "mcp",
        "source_id" => ctx.source.id,
        "raw_name" => @raw,
        "server_name" => ctx.source.name,
        "instructions_status" => "available",
        "instructions" => @instructions
      }
    }
  end

  defp legacy_mcp_document(ctx) do
    %{
      "tool_name" => ctx.mcp_name,
      "tool_revision" => ctx.source_snapshot.generation,
      "description" => @description,
      "input_kind" => "function",
      "schema" => @schema,
      "output_schema" => @output_schema,
      "source" => %{
        "kind" => "mcp",
        "source_id" => ctx.source.id,
        "raw_name" => @raw,
        "server_name" => ctx.source.name,
        "instructions_status" => "not_retained_legacy"
      }
    }
  end

  defp exec_document do
    %{
      "tool_name" => "exec",
      "tool_revision" => 1,
      "description" => @exec_description,
      "input_kind" => "custom",
      "format" => @exec_format
    }
  end

  defp assert_inspection(request, runtime, id, document) do
    native_messages = Conversation.status(runtime.root).messages

    [native] =
      for %{role: :tool, tool_call_id: ^id} = message <- native_messages, do: message

    assert %{"type" => "function_call_output", "call_id" => ^id, "output" => text} =
             output(request, id)

    assert native.result == %{content: text, is_error: false}
    assert {:ok, messages} = ProviderMessages.to_host(native_messages)

    [result] =
      for message <- messages,
          result = %ToolResult{} <- message.parts,
          result.tool_use_id == id,
          do: result

    assert result.is_error == false

    assert text == result.content
    assert Jason.decode!(text) == document
    assert is_binary(result.content)
    assert result.projection === nil
    result
  end

  defp replay(ctx, parts, uses, results, index \\ 7) do
    old = runtime(ctx.id)

    monitors =
      for pid <- [old.worker, old.adapter, old.binding.session, old.binding.resource_registry],
          do: {pid, Process.monitor(pid)}

    assert :ok = DynamicSupervisor.stop_session(ctx.id)

    for {pid, monitor} <- monitors,
        do: assert_receive({:DOWN, ^monitor, :process, ^pid, _}, 5_000)

    SessionHarness.ensure_running!(ctx.id)
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, ctx.id)
    assert worker != old.worker
    assert {_, %{runtime_pid: nil}} = :sys.get_state(worker)

    assert :ok =
             Worker.send_message(ctx.id, "Replay the persisted inspection without tool effects")

    assert_receive {:inspection_request, ^index, request, handler}, 15_000
    assert runtime(ctx.id).worker == worker
    assert_wire_history(request, uses, results)
    assert Agent.get(ctx.effects, & &1) == 1
    send(handler, :deliver)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    assert tool_parts(ctx.id) == parts
    assert_durable_results(ctx.id, results)
    assert Agent.get(ctx.effects, & &1) == 1
    assert :ok = DynamicSupervisor.stop_session(ctx.id)
  end

  defp assert_wire_history(request, uses, results) do
    for use <- uses do
      assert Enum.any?(request["input"], fn item ->
               item["type"] == "function_call" and item["call_id"] == use.tool_use_id and
                 item["name"] == ToolName.encode(use.tool) and
                 Jason.decode!(item["arguments"]) == use.input
             end)
    end

    for result <- results do
      assert %{
               "type" => "function_call_output",
               "call_id" => result.tool_use_id,
               "output" => result.content
             } in request["input"]
    end
  end

  defp assert_durable_results(id, results) do
    assert {:ok, turns} = Store.list_turns(id)
    durable = for turn <- turns, part <- turn.parts, part[:type] == "tool_result", do: part
    assert length(durable) == length(results)

    for result <- results do
      assert Enum.any?(durable, fn part ->
               part[:tool_use_id] == result.tool_use_id and part[:content] == result.content and
                 part[:projection] == result.projection and part[:is_error] == false
             end)
    end
  end

  defp runtime(id) do
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    {_, data} = :sys.get_state(worker)
    adapter = :sys.get_state(data.runtime_pid)

    %{
      worker: worker,
      adapter: data.runtime_pid,
      root: adapter.root,
      binding: adapter.binding,
      run_id: adapter.run_id,
      store: adapter.store
    }
  end

  defp operations(runtime, type) do
    assert {:ok, aggregate} = Synapsis.Runtime.Store.load(runtime.store.namespace, runtime.run_id)
    for {_, intent} <- aggregate.run.execution_intents, intent.type == type, do: intent.operation
  end

  defp tool_parts(id),
    do:
      for(
        message <- Synapsis.Sessions.get_messages(id),
        part <- message.parts,
        match?(%ToolUse{}, part) or match?(%ToolResult{}, part),
        do: part
      )

  defp declaration(request, name),
    do: Enum.find(request["tools"], &(&1["name"] == ToolName.encode(name)))

  defp names(request), do: request["tools"] |> Enum.map(& &1["name"]) |> Enum.sort()

  defp output(request, id),
    do:
      Enum.find(request["input"], &(&1["call_id"] == id and &1["type"] == "function_call_output"))

  defp json(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp json_response(conn, value),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(value))

  defp calls(conn, calls) do
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
