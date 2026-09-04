defmodule Synapsis.MCPTest do
  use ExUnit.Case, async: false

  alias Synapsis.Config.Store
  alias Synapsis.MCPConfig
  alias Synapsis.MCPConfigs
  alias Synapsis.Tool.Registry

  setup do
    Synapsis.DataCase.clear_config_store(:backplane)

    assert {:ok, _connection} =
             Store.put(:backplane, %{"id" => "source-1", "enabled" => true})

    on_exit(fn -> Synapsis.DataCase.clear_config_store(:backplane) end)

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
    assert {:ok, _registered} = Registry.lookup(tool)

    assert name in Synapsis.MCP.list()

    :ok = Synapsis.MCP.stop(name)
    assert wait_until(fn -> match?({:error, :not_found}, Registry.lookup(tool)) end)
    refute name in Synapsis.MCP.list()
  end

  test "restart reports discovery failure before returning" do
    bypass = Bypass.open()
    {:ok, mode} = Agent.start_link(fn -> :available end)

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      response =
        case request do
          %{"id" => id, "method" => "initialize"} = req ->
            %{
              "jsonrpc" => "2.0",
              "id" => id,
              "result" => %{
                "protocolVersion" => req["params"]["protocolVersion"] || "2025-06-18",
                "capabilities" => %{"tools" => %{}},
                "serverInfo" => %{"name" => "x", "version" => "0"}
              }
            }

          %{"id" => id, "method" => "tools/list"} ->
            case Agent.get_and_update(mode, fn
                   :fail_once -> {:unavailable, :available}
                   current -> {current, current}
                 end) do
              :available ->
                %{
                  "jsonrpc" => "2.0",
                  "id" => id,
                  "result" => %{
                    "tools" => [
                      %{
                        "name" => "echo",
                        "description" => "e",
                        "inputSchema" => %{"type" => "object"}
                      }
                    ]
                  }
                }

              :unavailable ->
                %{
                  "jsonrpc" => "2.0",
                  "id" => id,
                  "error" => %{"code" => -32_603, "message" => "replacement unavailable"}
                }
            end

          _notification ->
            nil
        end

      if response do
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      else
        Plug.Conn.resp(conn, 202, "")
      end
    end)

    Bypass.stub(bypass, "GET", "/mcp", fn conn -> Plug.Conn.resp(conn, 200, "") end)

    name = "restart_readiness_#{System.unique_integer([:positive])}"

    config = %MCPConfig{
      name: name,
      transport: "streamable_http",
      url: "http://localhost:#{bypass.port}"
    }

    on_exit(fn -> Synapsis.MCP.stop(name) end)

    assert {:ok, _pid} = Synapsis.MCP.start(config)
    tool = "mcp:#{name}:echo"
    assert wait_until(fn -> match?({:ok, _}, Registry.lookup(tool)) end)

    Agent.update(mode, fn _ -> :fail_once end)

    assert {:error, {:discover_failed, _reason}} = Synapsis.MCP.restart(config)
    assert wait_until(fn -> match?({:error, :not_found}, Registry.lookup(tool)) end)
    refute name in Synapsis.MCP.list()
  end

  test "restart reports cleanup timeout when a registered runtime cannot be stopped", %{
    bypass: bypass
  } do
    name = "restart_cleanup_#{System.unique_integer([:positive])}"
    parent = self()

    rogue =
      spawn(fn ->
        {:ok, _value} = Elixir.Registry.register(Synapsis.MCP.Registry, name, nil)
        send(parent, {:rogue_registered, self()})

        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn ->
      send(rogue, :stop)
      wait_until(fn -> not Process.alive?(rogue) end)
    end)

    assert_receive {:rogue_registered, ^rogue}

    config = %MCPConfig{
      name: name,
      transport: "streamable_http",
      url: "http://localhost:#{bypass.port}"
    }

    assert {:error, {:restart_cleanup_failed, {:runtime_stop_timeout, ^name}}} =
             Synapsis.MCP.restart(config)

    refute_receive {:mcp_request, _method}, 200
    assert Process.alive?(rogue)
  end

  test "unavailable managed configs cannot start or remain registered after restart", %{
    bypass: bypass
  } do
    name = "unavailable_facade_#{System.unique_integer([:positive])}"
    on_exit(fn -> Synapsis.MCP.stop(name) end)

    source_config = %{
      "managed_by" => "backplane",
      "backplane_source_id" => "source-1",
      "backplane_available" => true,
      "backplane_tools" => [%{"external_id" => "echo", "backplane_available" => true}]
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

  test "restart stops a renamed runtime by persisted config id after deletion", %{bypass: bypass} do
    old_name = "stale_rename_old_#{System.unique_integer([:positive])}"
    new_name = "stale_rename_new_#{System.unique_integer([:positive])}"

    {:ok, stale} =
      MCPConfigs.create(%{
        name: old_name,
        transport: "streamable_http",
        url: "http://localhost:#{bypass.port}",
        enabled: true
      })

    on_exit(fn ->
      Enum.each([old_name, new_name], &Synapsis.MCP.stop/1)
      if current = MCPConfigs.get(stale.id), do: MCPConfigs.delete(current)
    end)

    assert {:ok, renamed} = MCPConfigs.update(stale, %{name: new_name})
    assert {:ok, pid} = Synapsis.MCP.start(stale)

    tool = "mcp:#{new_name}:echo"
    assert wait_until(fn -> match?({:ok, _}, Registry.lookup(tool)) end)
    assert new_name in Synapsis.MCP.list()

    assert {:ok, _deleted} = MCPConfigs.delete(renamed)
    assert {:error, :mcp_unavailable} = Synapsis.MCP.restart(stale)

    assert wait_until(fn -> not Process.alive?(pid) end)
    assert wait_until(fn -> match?({:error, :not_found}, Registry.lookup(tool)) end)
    refute new_name in Synapsis.MCP.list()
  end

  test "restart replaces an intermediate renamed runtime by config id", %{bypass: bypass} do
    old_name = "multi_rename_old_#{System.unique_integer([:positive])}"
    middle_name = "multi_rename_middle_#{System.unique_integer([:positive])}"
    new_name = "multi_rename_new_#{System.unique_integer([:positive])}"

    {:ok, stale} =
      MCPConfigs.create(%{
        name: old_name,
        transport: "streamable_http",
        url: "http://localhost:#{bypass.port}",
        enabled: true
      })

    on_exit(fn ->
      Enum.each([old_name, middle_name, new_name], &Synapsis.MCP.stop/1)
      if current = MCPConfigs.get(stale.id), do: MCPConfigs.delete(current)
    end)

    assert {:ok, middle} = MCPConfigs.update(stale, %{name: middle_name})
    assert {:ok, middle_pid} = Synapsis.MCP.start(stale)

    middle_tool = "mcp:#{middle_name}:echo"
    assert wait_until(fn -> match?({:ok, _}, Registry.lookup(middle_tool)) end)

    assert {:ok, _current} = MCPConfigs.update(middle, %{name: new_name})
    assert {:error, _reason} = Synapsis.MCP.start(stale)

    assert [{^middle_pid, _value}] =
             Elixir.Registry.lookup(Synapsis.MCP.Registry, {:config_id, stale.id})

    refute new_name in Synapsis.MCP.list()

    assert :ok = Synapsis.MCP.restart(stale)

    new_tool = "mcp:#{new_name}:echo"
    assert wait_until(fn -> not Process.alive?(middle_pid) end)
    assert wait_until(fn -> match?({:error, :not_found}, Registry.lookup(middle_tool)) end)
    assert wait_until(fn -> match?({:ok, _}, Registry.lookup(new_tool)) end)

    assert [{new_pid, _value}] =
             Elixir.Registry.lookup(Synapsis.MCP.Registry, {:config_id, stale.id})

    assert Process.alive?(new_pid)
    assert Enum.all?(Synapsis.MCP.list(), &is_binary/1)

    assert Enum.filter(Synapsis.MCP.list(), &(&1 in [old_name, middle_name, new_name])) == [
             new_name
           ]
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
