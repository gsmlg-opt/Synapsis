defmodule Synapsis.MCP.ServerTest do
  use ExUnit.Case, async: false

  alias Synapsis.Config.Store
  alias Synapsis.MCP.Server
  alias Synapsis.MCPConfig

  setup do
    Synapsis.DataCase.clear_config_store(:backplane)

    assert {:ok, _connection} =
             Store.put(:backplane, %{"id" => "source-1", "enabled" => true})

    on_exit(fn -> Synapsis.DataCase.clear_config_store(:backplane) end)

    bypass = Gaoxy.Test.open()
    {:ok, bypass: bypass}
  end

  defp stub_mcp(bypass, server_name, call_observer \\ nil, tools \\ nil) do
    tools =
      tools ||
        [
          %{"name" => "echo", "description" => "e", "inputSchema" => %{"type" => "object"}}
        ]

    Gaoxy.Test.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      req = Jason.decode!(body)
      handle_rpc(conn, req, server_name, call_observer, tools)
    end)

    # tolerate any other requests the MCP client makes (GET sse channel, etc.)
    Gaoxy.Test.stub(bypass, "GET", "/mcp", fn conn ->
      Plug.Conn.resp(conn, 200, "")
    end)

    Gaoxy.Test.stub(bypass, "DELETE", "/mcp", fn conn ->
      Plug.Conn.resp(conn, 200, "")
    end)
  end

  defp handle_rpc(conn, %{"id" => id} = req, server_name, call_observer, tools) do
    result =
      case req["method"] do
        "initialize" ->
          %{
            "protocolVersion" => req["params"]["protocolVersion"] || "2024-11-05",
            "capabilities" => %{"tools" => %{}},
            "serverInfo" => %{"name" => server_name, "version" => "0"}
          }

        "tools/list" ->
          %{"tools" => tools}

        "tools/call" ->
          if call_observer, do: send(call_observer, {:mcp_tool_called, req["params"]})

          if req["params"]["name"] == "pending" do
            send(call_observer, {:mcp_tool_pending, id})
            :pending
          else
            %{"content" => [%{"type" => "text", "text" => req["params"]["arguments"]["text"]}]}
          end

        _ ->
          %{}
      end

    if result == :pending do
      Plug.Conn.resp(conn, 202, "")
    else
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}))
    end
  end

  defp handle_rpc(
         conn,
         %{"method" => "notifications/cancelled", "params" => params},
         _server_name,
         call_observer,
         _tools
       ) do
    if call_observer, do: send(call_observer, {:mcp_tool_cancelled, params})
    Plug.Conn.resp(conn, 202, "")
  end

  defp handle_rpc(conn, _notification, _server_name, _call_observer, _tools) do
    Plug.Conn.resp(conn, 202, "")
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      tries <= 0 ->
        false

      fun.() ->
        true

      true ->
        Process.sleep(20)
        wait_until(fun, tries - 1)
    end
  end

end
