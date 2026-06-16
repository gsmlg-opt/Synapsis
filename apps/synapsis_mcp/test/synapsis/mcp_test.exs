defmodule Synapsis.MCPTest do
  use ExUnit.Case, async: false

  alias Synapsis.MCPConfig
  alias Synapsis.Tool.Registry

  setup do
    bypass = Bypass.open()

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      handle(conn, Jason.decode!(body))
    end)

    Bypass.stub(bypass, "GET", "/mcp", fn conn -> Plug.Conn.resp(conn, 200, "") end)
    {:ok, bypass: bypass}
  end

  defp handle(conn, %{"id" => id} = req) do
    result =
      case req["method"] do
        "initialize" ->
          %{
            "protocolVersion" => req["params"]["protocolVersion"] || "2025-06-18",
            "capabilities" => %{"tools" => %{}},
            "serverInfo" => %{"name" => "x", "version" => "0"}
          }

        "tools/list" ->
          %{
            "tools" => [
              %{"name" => "echo", "description" => "e", "inputSchema" => %{"type" => "object"}}
            ]
          }

        _ ->
          %{}
      end

    conn
    |> Plug.Conn.put_resp_header("content-type", "application/json")
    |> Plug.Conn.resp(200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}))
  end

  defp handle(conn, _notification), do: Plug.Conn.resp(conn, 200, "")

  test "start, restart resets tools, stop removes them", %{bypass: bypass} do
    name = "facade_#{System.unique_integer([:positive])}"

    cfg = %MCPConfig{
      name: name,
      transport: "streamable_http",
      url: "http://localhost:#{bypass.port}"
    }

    {:ok, _} = Synapsis.MCP.start(cfg)
    tool = "mcp:#{name}:echo"
    assert wait_until(fn -> match?({:ok, _}, Registry.lookup(tool)) end)

    :ok = Synapsis.MCP.restart(cfg)
    assert wait_until(fn -> match?({:ok, _}, Registry.lookup(tool)) end)

    assert name in Synapsis.MCP.list()

    :ok = Synapsis.MCP.stop(name)
    assert wait_until(fn -> match?({:error, :not_found}, Registry.lookup(tool)) end)
    refute name in Synapsis.MCP.list()
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
