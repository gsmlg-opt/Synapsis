defmodule Synapsis.MCP.ServerTest do
  use ExUnit.Case, async: false

  alias Synapsis.MCP.Server
  alias Synapsis.MCPConfig
  alias Synapsis.Tool.Registry

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass}
  end

  defp stub_mcp(bypass, server_name) do
    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      req = Jason.decode!(body)
      handle_rpc(conn, req, server_name)
    end)

    # tolerate any other requests the MCP client makes (GET sse channel, etc.)
    Bypass.stub(bypass, "GET", "/mcp", fn conn ->
      Plug.Conn.resp(conn, 200, "")
    end)

    Bypass.stub(bypass, "DELETE", "/mcp", fn conn ->
      Plug.Conn.resp(conn, 200, "")
    end)
  end

  defp handle_rpc(conn, %{"id" => id} = req, server_name) do
    result =
      case req["method"] do
        "initialize" ->
          %{
            "protocolVersion" => req["params"]["protocolVersion"] || "2024-11-05",
            "capabilities" => %{"tools" => %{}},
            "serverInfo" => %{"name" => server_name, "version" => "0"}
          }

        "tools/list" ->
          %{
            "tools" => [
              %{"name" => "echo", "description" => "e", "inputSchema" => %{"type" => "object"}}
            ]
          }

        "tools/call" ->
          %{"content" => [%{"type" => "text", "text" => req["params"]["arguments"]["text"]}]}

        _ ->
          %{}
      end

    conn
    |> Plug.Conn.put_resp_header("content-type", "application/json")
    |> Plug.Conn.resp(200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}))
  end

  defp handle_rpc(conn, _notification, _server_name) do
    Plug.Conn.resp(conn, 202, "")
  end

  test "discovers tools, routes calls, and purges on stop", %{bypass: bypass} do
    name = "srv_#{System.unique_integer([:positive])}"
    stub_mcp(bypass, name)

    cfg = %MCPConfig{
      name: name,
      transport: "streamable_http",
      url: "http://localhost:#{bypass.port}"
    }

    {:ok, pid} = Server.start_link(cfg)

    tool = "mcp:#{name}:echo"
    assert wait_until(fn -> match?({:ok, _}, Registry.lookup(tool)) end)

    assert {:ok, "hi"} = GenServer.call(pid, {:execute, tool, %{"text" => "hi"}, %{}}, 10_000)

    GenServer.stop(pid)
    assert wait_until(fn -> match?({:error, :not_found}, Registry.lookup(tool)) end)
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
