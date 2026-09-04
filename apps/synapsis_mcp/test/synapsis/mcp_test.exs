defmodule Synapsis.MCPTest do
  use ExUnit.Case, async: false

  alias Synapsis.MCPConfig
  alias Synapsis.MCPConfigs
  alias Synapsis.Tool.Registry

  setup do
    bypass = Bypass.open()
    test_pid = self()

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      send(test_pid, {:mcp_request, request["method"]})
      handle(conn, request)
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

  defp handle(conn, _notification), do: Plug.Conn.resp(conn, 202, "")

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

  test "unavailable managed configs cannot start or remain registered after restart", %{
    bypass: bypass
  } do
    name = "unavailable_facade_#{System.unique_integer([:positive])}"
    on_exit(fn -> Synapsis.MCP.stop(name) end)

    source_config = %{
      "managed_by" => "backplane",
      "backplane_source_id" => "source-1",
      "backplane_available" => true
    }

    available = %MCPConfig{
      name: name,
      transport: "streamable_http",
      url: "http://localhost:#{bypass.port}",
      config: source_config
    }

    unavailable = %{
      available
      | config: Map.put(source_config, "backplane_available", false)
    }

    assert {:error, :mcp_unavailable} = Synapsis.MCP.start(unavailable)
    refute name in Synapsis.MCP.list()

    assert {:ok, _pid} = Synapsis.MCP.start(available)
    tool = "mcp:#{name}:echo"
    assert wait_until(fn -> match?({:ok, _}, Registry.lookup(tool)) end)

    assert {:error, :mcp_unavailable} = Synapsis.MCP.restart(unavailable)
    assert wait_until(fn -> match?({:error, :not_found}, Registry.lookup(tool)) end)
    refute name in Synapsis.MCP.list()
  end

  test "restart rejects a stale enabled struct after its persisted record is disabled", %{
    bypass: bypass
  } do
    name = "stale_disabled_#{System.unique_integer([:positive])}"

    {:ok, stale} =
      MCPConfigs.create(%{
        name: name,
        transport: "streamable_http",
        url: "http://localhost:#{bypass.port}",
        enabled: true
      })

    on_exit(fn ->
      Synapsis.MCP.stop(name)
      if current = MCPConfigs.get(stale.id), do: MCPConfigs.delete(current)
    end)

    assert {:ok, persisted} = MCPConfigs.update(stale, %{enabled: false})
    refute persisted.enabled
    assert stale.enabled

    result = Synapsis.MCP.restart(stale)

    refute_receive {:mcp_request, _method}, 200
    assert {:error, :mcp_unavailable} = result
    refute name in Synapsis.MCP.list()
  end

  test "start rejects a stale enabled struct after its persisted record is deleted", %{
    bypass: bypass
  } do
    name = "stale_deleted_#{System.unique_integer([:positive])}"

    {:ok, stale} =
      MCPConfigs.create(%{
        name: name,
        transport: "streamable_http",
        url: "http://localhost:#{bypass.port}",
        enabled: true
      })

    on_exit(fn ->
      Synapsis.MCP.stop(name)
      if current = MCPConfigs.get(stale.id), do: MCPConfigs.delete(current)
    end)

    assert {:ok, _deleted} = MCPConfigs.delete(stale)
    assert MCPConfigs.get(stale.id) == nil

    result = Synapsis.MCP.start(stale)

    refute_receive {:mcp_request, _method}, 200
    assert {:error, :mcp_unavailable} = result
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
