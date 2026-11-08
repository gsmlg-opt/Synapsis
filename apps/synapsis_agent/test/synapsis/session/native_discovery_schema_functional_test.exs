defmodule Synapsis.Session.NativeDiscoverySchemaFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Conversation
  alias Backplane.AgentRuntime.Codex.Session
  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Agent.Tools.Decisions
  alias Synapsis.MCP.Server
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{Store, Worker}
  alias Synapsis.{AgentConfigs, Providers}

  @moduletag :tmp_dir
  @moduletag timeout: 90_000
  @decision "synapsis::decision_evaluate"
  @raw "read::schema_fixture"
  @description "Read a nested schema fixture.\nPreserve every supplied field and ordered label. 雪 😀"
  @schema %{
    "type" => "object",
    "description" => "Complete nested input contract",
    "properties" => %{
      "document" => %{
        "type" => "object",
        "properties" => %{
          "title" => %{"type" => "string", "minLength" => 1, "description" => "Original title"},
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
      },
      "include_notes" => %{"type" => "boolean", "default" => false}
    },
    "required" => ["document"],
    "additionalProperties" => false
  }
  @input %{
    "document" => %{
      "title" => "Published 雪",
      "labels" => [
        %{"kind" => "secondary", "weight" => 0.25},
        %{"kind" => "primary", "weight" => 0.75}
      ]
    },
    "include_notes" => true
  }
  @decision_input %{
    "state" => "The fixture is ready.",
    "questions" => %{"ready" => %{"type" => "boolean", "instructions" => "Is it ready?"}}
  }

  test "published function schemas, descriptions and custom grammar reach HTTP before direct-only use",
       %{tmp_dir: root} do
    ctx = setup_context(root)
    install_provider(ctx)
    SessionHarness.subscribe!(ctx.id)
    SessionHarness.ensure_running!(ctx.id)
    assert :ok = Worker.send_message(ctx.id, "Discover and use the selected schema fixtures")

    assert_receive {:schema_request, 0, initial, handler}, 15_000
    runtime = runtime(ctx.id)

    issued =
      :sys.get_state(runtime.adapter).tool_contexts[{runtime.run_id, 1}].snapshot.issued_descriptors

    assert names(initial) == ["tool_search", "wait"]
    assert issued[ctx.mcp_name].schema == @schema
    assert issued[ctx.mcp_name].description == @description
    assert issued[@decision].backend == Decisions
    assert issued[@decision].codex_exposure == :direct_model_only
    assert issued["exec"].codex_input_kind == :custom
    assert Conversation.status(runtime.root).catalog_revision == 1
    send(handler, :deliver)

    assert_receive {:schema_request, 1, published, handler}, 15_000

    assert names(published) ==
             Enum.sort(Enum.map(ctx.selection ++ ["tool_search"], &ToolName.encode/1))

    assert Conversation.status(runtime.root).catalog_revision == 2
    current = :sys.get_state(runtime.root).catalog

    for name <- [ctx.mcp_name, @decision, "exec"] do
      assert current.registry.tools[name] === issued[name]
    end

    assert declaration(published, ctx.mcp_name) == %{
             "type" => "function",
             "name" => ToolName.encode(ctx.mcp_name),
             "description" => @description,
             "parameters" => @schema
           }

    assert declaration(published, @decision) == %{
             "type" => "function",
             "name" => ToolName.encode(@decision),
             "description" => issued[@decision].description,
             "parameters" => issued[@decision].schema
           }

    assert declaration(published, "exec") == %{
             "type" => "custom",
             "name" => "exec",
             "description" => issued["exec"].description,
             "format" => json(issued["exec"].codex_format)
           }

    assert %{"type" => "grammar", "syntax" => "lark", "definition" => grammar} =
             declaration(published, "exec")["format"]

    assert is_binary(grammar) and byte_size(grammar) > 0
    assert output(published, "discover")["output"] =~ "staged"
    assert {:ok, aggregate} = Synapsis.Runtime.Store.load(runtime.store.namespace, runtime.run_id)

    assert aggregate.run.context.conversation.catalog_publication ==
             Conversation.status(runtime.root).catalog_publication

    assert :sys.get_state(runtime.binding.session).active.catalog_revision == 2

    assert Enum.any?(aggregate.run.execution_intents, fn {_, intent} ->
             intent.type == :provider and intent.operation.catalog_revision == 2
           end)

    send(handler, :deliver)
    assert_receive {:schema_mcp_call, %{"name" => @raw, "arguments" => @input}}, 15_000

    assert_receive {:schema_decision_call, decision_request}, 15_000

    assert decision_request == %{
             "model" => "explicit-discovery-decision",
             "input" => "The fixture is ready.",
             "questions" => [
               %{"type" => "predicate", "name" => "ready", "instructions" => "Is it ready?"}
             ]
           }

    assert_receive {:schema_request, 2, used, handler}, 15_000
    send(handler, :deliver)
    assert_receive {:schema_request, 3, inventoried, handler}, 15_000

    assert {:ok, host_messages} =
             Synapsis.Agent.Runtime.ProviderMessages.to_host(
               Conversation.status(runtime.root).messages
             )

    results = for message <- host_messages, part = %ToolResult{} <- message.parts, do: part
    mcp = Enum.find(results, &(&1.tool_use_id == "nested-schema"))
    decision = Enum.find(results, &(&1.tool_use_id == "direct-decision"))
    inventory = Enum.find(results, &(&1.tool_use_id == "metadata"))
    assert mcp.is_error == false
    assert decision.is_error == false
    assert inventory.is_error == false
    assert mcp.projection["result"]["structured"] == @input

    assert %{"status" => "ok", "result" => decision_result, "provenance" => provenance} =
             Jason.decode!(decision.content)

    assert decision_result == %{
             "model" => "fixture-decision-result",
             "answers" => %{"ready" => %{"type" => "boolean", "probabilityTrue" => 0.875}},
             "usage" => %{"inputTokens" => 7, "outputTokens" => 0}
           }

    assert provenance["providerId"] == ctx.decision.id
    assert output(used, "nested-schema")["output"] == mcp.content
    assert output(used, "direct-decision")["output"] == decision.content
    assert output(inventoried, "metadata")["output"] == inventory.content
    assert inventory.projection["result"]["status"] == "completed"

    assert [%{"type" => "text", "text" => metadata_json}] =
             inventory.projection["result"]["output"]

    expected_metadata =
      for name <- [ctx.mcp_name, "tool_search"] do
        %{
          "name" => String.replace(name, "::", "__"),
          "tool_name" => name,
          "description" => current.registry.tools[name].description,
          "input_kind" => "function"
        }
      end

    assert Enum.sort_by(Jason.decode!(metadata_json), & &1["tool_name"]) ==
             Enum.sort_by(expected_metadata, & &1["tool_name"])

    send(handler, :deliver)
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    assert %{phase: :idle} = Session.status(runtime.binding.session)

    parts =
      for message <- Synapsis.Sessions.get_messages(ctx.id),
          part <- message.parts,
          match?(%ToolUse{}, part) or match?(%ToolResult{}, part),
          do: part

    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))

    assert Enum.map(uses, &{&1.tool_use_id, &1.tool}) == [
             {"discover", "tool_search"},
             {"nested-schema", ctx.mcp_name},
             {"direct-decision", @decision},
             {"metadata", "exec"}
           ]

    for part <- parts do
      assert {:ok, dump} = Synapsis.Part.dump(part)
      assert {:ok, ^part} = dump |> json() |> Synapsis.Part.load()
    end

    assert {:ok, turns} = Store.list_turns(ctx.id)
    durable = for turn <- turns, part <- turn.parts, part[:type] == "tool_result", do: part
    assert length(durable) == 4

    for result <- results do
      assert Enum.any?(
               durable,
               &(&1[:tool_use_id] == result.tool_use_id and
                   &1[:content] == result.content and &1[:projection] == result.projection and
                   &1[:is_error] == false)
             )
    end

    assert Agent.get(ctx.effects, & &1) == %{mcp: 1, decision: 1}
    assert AgentConfigs.get(ctx.harness.agent_config.id).tools == ctx.selection
  end

  defp setup_context(root) do
    owner = self()
    effects = start_supervised!({Agent, fn -> %{mcp: 0, decision: 0} end})
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
              "serverInfo" => %{"name" => "schema-fixture", "version" => "1"}
            }

          "tools/list" ->
            %{
              "tools" => [
                %{
                  "name" => @raw,
                  "description" => @description,
                  "annotations" => %{"readOnlyHint" => true},
                  "inputSchema" => @schema
                }
              ]
            }

          "tools/call" ->
            Agent.update(effects, &Map.update!(&1, :mcp, fn n -> n + 1 end))
            send(owner, {:schema_mcp_call, request["params"]})

            %{
              "content" => [%{"type" => "text", "text" => "Nested schema consumed"}],
              "structuredContent" => request["params"]["arguments"],
              "isError" => false
            }

          _ ->
            %{}
        end

      if Map.has_key?(request, "id"),
        do: json_response(conn, %{"jsonrpc" => "2.0", "id" => request["id"], "result" => result}),
        else: Plug.Conn.resp(conn, 202, "")
    end)

    for method <- ["GET", "DELETE"],
        do: Gaoxy.Test.stub(fixture, method, "/mcp", &Plug.Conn.resp(&1, 200, ""))

    assert {:ok, source} =
             Synapsis.MCPConfigs.create(%{
               name: "schema-mcp-#{System.unique_integer([:positive])}",
               transport: "streamable_http",
               url: String.trim_trailing(Gaoxy.Test.url(fixture), "/")
             })

    source_pid = start_supervised!(Supervisor.child_spec({Server, source}, restart: :temporary))
    assert :ok = Server.await_ready(source_pid)
    on_exit(fn -> Synapsis.MCPConfigs.delete(source) end)

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
               api_key_encrypted: "schema-fixture"
             })

    assert {:ok, decision} =
             Providers.create(%{
               name: "discovery-decision-#{System.unique_integer([:positive])}",
               type: "openai_responses",
               base_url: Gaoxy.Test.url(fixture, "/v1/"),
               api_key_encrypted: "decision-fixture"
             })

    on_exit(fn -> Providers.delete(decision.id) end)

    Gaoxy.Test.stub(fixture, "POST", "/v1/decisions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      Agent.update(effects, &Map.update!(&1, :decision, fn n -> n + 1 end))
      send(owner, {:schema_decision_call, Jason.decode!(body)})

      json_response(conn, %{
        "model" => "fixture-decision-result",
        "answers" => [%{"name" => "ready", "type" => "predicate", "probability" => 0.875}],
        "usage" => %{"input_tokens" => 7, "output_tokens" => 0, "total_tokens" => 7}
      })
    end)

    mcp_name = "mcp::#{source.id}::#{@raw}"
    selection = [mcp_name, @decision, "exec", "wait"]

    config =
      h.agent_config.config
      |> Map.put("deferred_tool_names", [mcp_name, @decision, "exec"])
      |> Map.put("decision", %{
        "provider" => decision.name,
        "model" => "explicit-discovery-decision"
      })

    assert {:ok, _} = AgentConfigs.update(h.agent_config, %{tools: selection, config: config})

    %{
      harness: h,
      id: h.session.id,
      mcp_name: mcp_name,
      selection: selection,
      effects: effects,
      decision: decision
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

      send(owner, {:schema_request, index, request, self()})

      receive do
        :deliver -> :ok
      after
        15_000 -> raise "schema provider handshake timed out"
      end

      case index do
        0 ->
          calls(conn, [
            {"discover", "tool_search", %{"query" => "read decision JavaScript", "limit" => 8}}
          ])

        1 ->
          calls(conn, [
            {"nested-schema", ctx.mcp_name, @input},
            {"direct-decision", @decision, @decision_input}
          ])

        2 ->
          custom_call(conn, "metadata", "text(ALL_TOOLS);")

        3 ->
          sse(conn, [
            %{"type" => "response.output_text.delta", "delta" => "Schema discovery complete"},
            completed([])
          ])
      end
    end)
  end

  defp runtime(id) do
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    {_, data} = :sys.get_state(worker)
    adapter = :sys.get_state(data.runtime_pid)

    %{
      adapter: data.runtime_pid,
      root: adapter.root,
      binding: adapter.binding,
      run_id: adapter.run_id,
      store: adapter.store
    }
  end

  defp declaration(request, name),
    do: Enum.find(request["tools"], &(&1["name"] == ToolName.encode(name)))

  defp names(request), do: request["tools"] |> Enum.map(& &1["name"]) |> Enum.sort()

  defp output(request, id),
    do:
      Enum.find(
        request["input"],
        &(&1["call_id"] == id and &1["type"] in ~w(function_call_output custom_tool_call_output))
      )

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

  defp custom_call(conn, id, input) do
    item = %{
      "type" => "custom_tool_call",
      "id" => id <> "-item",
      "call_id" => id,
      "name" => "exec",
      "input" => input
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
        "delta" => input
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
