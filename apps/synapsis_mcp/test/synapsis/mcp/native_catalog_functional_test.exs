defmodule Synapsis.MCP.NativeCatalogFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.MCP
  alias Synapsis.MCP.Server
  alias Synapsis.MCPConfigs

  setup do
    fixture = Gaoxy.Test.open()
    owner = self()

    state =
      start_supervised!({Agent, fn -> %{tools: [tool("echo", "Original")], fail: false} end})

    Gaoxy.Test.stub(fixture, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      current = Agent.get(state, & &1)

      response =
        case request["method"] do
          "initialize" ->
            %{
              "result" => %{
                "protocolVersion" => request["params"]["protocolVersion"],
                "capabilities" => %{"tools" => %{}},
                "serverInfo" => %{"name" => "native-catalog", "version" => "1"}
              }
            }

          "tools/list" when current.fail ->
            %{"error" => %{"code" => -32603, "message" => "Discovery failed"}}

          "tools/list" ->
            %{"result" => %{"tools" => current.tools}}

          "tools/call" ->
            send(owner, {:catalog_tool_called, request["params"]})

            %{
              "result" => %{
                "content" => [
                  %{"type" => "text", "text" => "first"},
                  %{"type" => "image", "mimeType" => "image/png", "data" => "aW1hZ2U="},
                  %{"type" => "text", "text" => "last"}
                ],
                "structuredContent" => %{"ordered" => true},
                "isError" => false
              }
            }

          _ ->
            %{"result" => %{}}
        end

      if Map.has_key?(request, "id") do
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(Map.merge(response, %{"jsonrpc" => "2.0", "id" => request["id"]}))
        )
      else
        Plug.Conn.resp(conn, 202, "")
      end
    end)

    for method <- ["GET", "DELETE"],
        do: Gaoxy.Test.stub(fixture, method, "/mcp", fn conn -> Plug.Conn.resp(conn, 200, "") end)

    {:ok, config} =
      MCPConfigs.create(%{
        name: "native-catalog-#{System.unique_integer([:positive])}",
        transport: "streamable_http",
        url: String.trim_trailing(Gaoxy.Test.url(fixture), "/")
      })

    Phoenix.PubSub.subscribe(Synapsis.PubSub, "tool_registry")
    {:ok, pid} = MCP.start(config)

    on_exit(fn ->
      MCP.stop(config.name)
      MCPConfigs.delete(config)
    end)

    assert :ok = Server.await_ready(pid)
    %{config: config, pid: pid, state: state}
  end

  test "same names and empty discoveries still publish source invalidation", ctx do
    id = ctx.config.id
    assert_receive {:mcp_source_catalog_changed, %{source_id: ^id, status: :ready}}
    Agent.update(ctx.state, &%{&1 | tools: [tool("echo", "Replacement")]})
    assert :ok = Server.refresh(ctx.pid)
    assert_receive {:mcp_source_catalog_changed, %{source_id: ^id, status: :ready}}
    assert {:ok, [%{description: "Replacement"}]} = Server.catalog(ctx.pid)

    Agent.update(ctx.state, &%{&1 | tools: []})
    assert :ok = Server.refresh(ctx.pid)
    assert_receive {:mcp_source_catalog_changed, %{source_id: ^id, status: :ready}}
    assert {:ok, []} = Server.catalog(ctx.pid)
    assert :ok = Server.refresh(ctx.pid)
    assert_receive {:mcp_source_catalog_changed, %{source_id: ^id, status: :ready}}
  end

  test "failed discovery invalidates metadata and reconnect publishes a fresh catalog", ctx do
    id = ctx.config.id
    assert_receive {:mcp_source_catalog_changed, %{source_id: ^id, status: :ready}}
    Agent.update(ctx.state, &%{&1 | fail: true})
    assert {:error, _} = Server.refresh(ctx.pid)
    assert_receive {:mcp_source_catalog_changed, %{source_id: ^id, status: :unavailable}}
    assert {:error, :mcp_unavailable} = Server.catalog(ctx.pid)
    assert [] = Enum.filter(MCP.source_catalog(), &(&1.mcp_config_id == id))

    Agent.update(ctx.state, &%{&1 | fail: false})
    assert :ok = MCP.restart(ctx.config)
    assert_receive {:mcp_source_catalog_changed, %{source_id: ^id, status: :stopped}}
    assert_receive {:mcp_source_catalog_changed, %{source_id: ^id, status: :ready}}, 2_000

    assert [%{mcp_tool_name: "echo"}] =
             Enum.filter(MCP.source_catalog(), &(&1.mcp_config_id == id))
  end

  test "stop publishes source invalidation and removes displayed tools", ctx do
    id = ctx.config.id
    assert_receive {:mcp_source_catalog_changed, %{source_id: ^id, status: :ready}}
    assert :ok = MCP.stop(ctx.config.name)
    assert_receive {:mcp_source_catalog_changed, %{source_id: ^id, status: :stopped}}
    assert [] = Enum.filter(MCP.source_catalog(), &(&1.mcp_config_id == id))
    refute ctx.config.name in MCP.list()
  end

  test "native calls preserve ordered raw content after legacy publication is removed", ctx do
    assert {:ok, snapshot} = MCP.runtime_snapshot(ctx.config.id)
    assert {:ok, result} = Server.runtime_call(snapshot, "echo", %{}, 2_000)

    assert result == %{
             "content" => [
               %{"type" => "text", "text" => "first"},
               %{"type" => "image", "mimeType" => "image/png", "data" => "aW1hZ2U="},
               %{"type" => "text", "text" => "last"}
             ],
             "structuredContent" => %{"ordered" => true},
             "isError" => false
           }

    assert_receive {:catalog_tool_called, %{"name" => "echo", "arguments" => %{}}}
  end

  defp tool(name, description),
    do: %{"name" => name, "description" => description, "inputSchema" => %{"type" => "object"}}
end
