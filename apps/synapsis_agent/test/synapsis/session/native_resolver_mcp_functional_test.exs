defmodule Synapsis.Session.NativeResolverMCPFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Agent.TestSupport.{AbortableHTTP, DeterministicProvider, SessionHarness}
  alias Synapsis.Config.Store, as: ConfigStore
  alias Synapsis.MCP.Server
  alias Synapsis.Part.ToolResult
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{Store, Worker}

  @moduletag :tmp_dir
  @raw_name "tools::read"
  @description "Read the selected native MCP source."
  @call_id "native-resolver-mcp-call"
  @arguments %{"label" => "retained"}
  @schema %{
    "type" => "object",
    "properties" => %{"label" => %{"type" => "string"}},
    "required" => ["label"],
    "additionalProperties" => false
  }

  test "saved UUID policy reaches native source schema, prompt, effect and durable Worker result",
       %{
         tmp_dir: root
       } do
    owner = self()
    calls = start_supervised!({Agent, fn -> [] end})
    fixture = Gaoxy.Test.open()
    install_source(fixture, calls, owner)

    {:ok, source} =
      Synapsis.MCPConfigs.create(%{
        name: "resolver-mcp-#{System.unique_integer([:positive, :monotonic])}",
        transport: "streamable_http",
        url: String.trim_trailing(Gaoxy.Test.url(fixture), "/")
      })

    on_exit(fn -> Synapsis.MCPConfigs.delete(source) end)
    source_pid = start_supervised!(Supervisor.child_spec({Server, source}, restart: :temporary))
    assert :ok = Server.await_ready(source_pid)

    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)
    name = "mcp::#{source.id}::#{@raw_name}"

    policy = %{
      "default" => "selected",
      "sources" => %{source.id => %{"mode" => "selected", "tools" => [@raw_name]}}
    }

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(harness.agent_config, %{
               tools: [name],
               config: Map.put(harness.agent_config.config, "mcp_selection", policy)
             })

    assert {:ok, agent_before} = ConfigStore.get(:agent, harness.agent_config.id)
    install_provider(harness, name, owner)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)

    assert :ok = Worker.send_message(harness.session.id, "Read the selected source label")
    assert_receive {:native_resolver_provider, 0, first, _handler}, 5_000
    assert [%{"type" => "function", "function" => function}] = first["tools"]
    assert function["name"] == ToolName.encode(name)
    assert function["description"] == @description
    assert function["parameters"] == @schema

    prompt =
      first["messages"]
      |> Enum.filter(&(&1["role"] == "system"))
      |> Enum.map_join("\n", &content_text(&1["content"]))

    assert prompt =~ "Selected tools:\n- #{name}: #{@description}"
    assert_receive {:native_resolver_source_call, source_call}, 5_000
    assert source_call == %{"name" => @raw_name, "arguments" => @arguments}
    assert_receive {:native_resolver_provider, 1, following, handler}, 5_000

    assert [%{"role" => "tool", "tool_call_id" => @call_id} = wire_result] =
             Enum.filter(following["messages"], &(&1["role"] == "tool"))

    send(handler, :complete_native_resolver_mcp)
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000

    assert [%ToolResult{tool_use_id: @call_id, is_error: false} = result] =
             for(
               message <- Synapsis.Sessions.get_messages(harness.session.id),
               part = %ToolResult{} <- message.parts,
               do: part
             )

    assert wire_result["content"] == result.content

    assert result.projection["result"]["content"] == [
             %{"type" => "text", "text" => "source label retained"}
           ]

    assert result.projection["result"]["structured"] == @arguments
    assert Agent.get(calls, & &1) == [source_call]
    assert length(Agent.get(harness.counter, & &1.provider_requests)) == 2
    assert {:ok, turns} = Store.list_turns(harness.session.id)
    durable_parts = for turn <- turns, part <- turn.parts, do: part

    assert Enum.filter(durable_parts, &(&1[:type] == "tool_result")) == [
             %{
               type: "tool_result",
               tool_use_id: @call_id,
               content: result.content,
               is_error: false,
               projection: result.projection
             }
           ]

    assert {:ok, ^agent_before} = ConfigStore.get(:agent, harness.agent_config.id)
  end

  defp install_source(fixture, calls, owner) do
    Gaoxy.Test.stub(fixture, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      result =
        case request["method"] do
          "initialize" ->
            %{
              "protocolVersion" => request["params"]["protocolVersion"],
              "capabilities" => %{"tools" => %{}},
              "serverInfo" => %{"name" => "native-resolver-fixture", "version" => "1"}
            }

          "tools/list" ->
            %{
              "tools" => [
                %{
                  "name" => @raw_name,
                  "description" => @description,
                  "annotations" => %{"readOnlyHint" => true},
                  "inputSchema" => @schema
                }
              ]
            }

          "tools/call" ->
            params = request["params"]
            Agent.update(calls, &(&1 ++ [params]))
            send(owner, {:native_resolver_source_call, params})

            %{
              "content" => [%{"type" => "text", "text" => "source label retained"}],
              "structuredContent" => @arguments,
              "isError" => false
            }

          _notification ->
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
  end

  defp install_provider(harness, name, owner) do
    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      index =
        Agent.get_and_update(harness.counter, fn state ->
          {length(state.provider_requests),
           %{state | provider_requests: state.provider_requests ++ [request]}}
        end)

      send(owner, {:native_resolver_provider, index, request, self()})

      case index do
        0 ->
          DeterministicProvider.send_sse(conn, [
            DeterministicProvider.tool_call_chunk(ToolName.encode(name), @call_id, @arguments),
            DeterministicProvider.finish_chunk("tool_calls")
          ])

        1 ->
          {:released, conn} =
            AbortableHTTP.await(conn, :complete_native_resolver_mcp, 10_000, owner)

          DeterministicProvider.send_sse(conn, [
            DeterministicProvider.text_chunk("Native source turn complete"),
            DeterministicProvider.finish_chunk("stop")
          ])
      end
    end)
  end

  defp content_text(content) when is_binary(content), do: content
  defp content_text(blocks) when is_list(blocks), do: Enum.map_join(blocks, & &1["text"])
end
