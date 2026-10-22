defmodule Synapsis.MCPTest do
  use ExUnit.Case, async: false

  alias Synapsis.Config.Store
  alias Synapsis.MCPConfig
  alias Synapsis.MCPConfigs
  alias Synapsis.Tool.Registry

  defmodule AliasRuntime do
    use GenServer

    def start_link(name) do
      GenServer.start_link(__MODULE__, :ok,
        name: {:via, Elixir.Registry, {Synapsis.MCP.Registry, name}}
      )
    end

    @impl true
    def init(:ok), do: {:ok, %{}}
  end

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

  test "provider deletion stops linked clients and purges their discovered tools", %{
    bypass: bypass
  } do
    name = "provider-cleanup-#{System.unique_integer([:positive])}"

    {:ok, provider} =
      Synapsis.Providers.create(%{
        name: name,
        type: "openai",
        preset: "backplane",
        base_url: "http://localhost:#{bypass.port}/v1"
      })

    {:ok, linked} =
      MCPConfigs.create(%{
        name: name,
        provider_id: provider.id,
        transport: "streamable_http",
        url: "http://localhost:#{bypass.port}/mcp"
      })

    {:ok, independent} =
      MCPConfigs.create(%{
        name: name <> "-independent",
        transport: "streamable_http",
        url: "http://localhost:#{bypass.port}/mcp"
      })

    on_exit(fn ->
      Synapsis.MCP.stop(linked.name)
      Synapsis.MCP.stop(independent.name)
      MCPConfigs.delete(independent)
      Synapsis.Providers.delete(provider.id)
    end)

    {:ok, linked_pid} = Synapsis.MCP.start(linked)
    {:ok, independent_pid} = Synapsis.MCP.start(independent)
    assert :ok = Synapsis.MCP.Server.await_ready(linked_pid)
    assert :ok = Synapsis.MCP.Server.await_ready(independent_pid)
    assert {:ok, _} = Registry.lookup("mcp:#{name}:echo")

    assert {:ok, _} = Synapsis.Providers.delete(provider.id)
    refute Process.alive?(linked_pid)
    assert {:error, :not_found} = Registry.lookup("mcp:#{name}:echo")
    assert MCPConfigs.get(linked.id) == nil
    assert Process.alive?(independent_pid)
    assert {:ok, _} = Registry.lookup("mcp:#{independent.name}:echo")
  end

  test "a partially failed provider deletion still cleans clients already removed from config", %{
    bypass: bypass
  } do
    name = "partial-cleanup-#{System.unique_integer([:positive])}"

    {:ok, provider} =
      Synapsis.Providers.create(%{
        name: name,
        type: "openai",
        preset: "backplane",
        base_url: "http://localhost:#{bypass.port}/v1"
      })

    {:ok, config} =
      MCPConfigs.create(%{
        name: name,
        provider_id: provider.id,
        transport: "streamable_http",
        url: "http://localhost:#{bypass.port}/mcp"
      })

    {:ok, _} =
      Store.put(:backplane, %{
        "id" => Ecto.UUID.generate(),
        "name" => name,
        "provider_id" => provider.id
      })

    {:ok, pid} = Synapsis.MCP.start(config)
    assert :ok = Synapsis.MCP.Server.await_ready(pid)

    on_exit(fn ->
      File.chmod(Store.file_path(:backplane), 0o600)
      Synapsis.MCP.stop(name)
      Synapsis.Providers.delete(provider.id)
    end)

    File.chmod!(Store.file_path(:backplane), 0o400)

    assert {:error, _} = Synapsis.Providers.delete(provider.id)
    refute Process.alive?(pid)
    assert MCPConfigs.get(config.id) == nil
    assert {:error, :not_found} = Registry.lookup("mcp:#{name}:echo")
    assert {:ok, _} = Synapsis.Providers.get(provider.id)
    File.chmod!(Store.file_path(:backplane), 0o600)
    assert {:ok, _} = Synapsis.Providers.delete(provider.id)
  end

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

  test "a failed client stops its runtime without restarting unrelated MCP infrastructure", %{
    bypass: bypass
  } do
    name = "failed-client-#{System.unique_integer([:positive])}"

    {:ok, config} =
      MCPConfigs.create(%{
        name: name,
        transport: "streamable_http",
        url: "http://localhost:#{bypass.port}"
      })

    on_exit(fn ->
      Synapsis.MCP.stop(name)
      MCPConfigs.delete(config)
    end)

    {:ok, server} = Synapsis.MCP.start(config)
    assert :ok = Synapsis.MCP.Server.await_ready(server)
    task_supervisor = Process.whereis(Synapsis.MCP.TaskSupervisor)
    dynamic_supervisor = Process.whereis(Synapsis.MCP.DynamicSupervisor)
    monitor = Process.monitor(server)
    client_supervisor = :sys.get_state(server).supervisor
    Process.exit(client_supervisor, :kill)

    assert_receive {:DOWN, ^monitor, :process, ^server, {:shutdown, {:client_exited, :killed}}},
                   2_000

    assert wait_until(fn -> Elixir.Registry.lookup(Synapsis.MCP.Registry, name) == [] end)
    assert Process.whereis(Synapsis.MCP.TaskSupervisor) == task_supervisor
    assert Process.whereis(Synapsis.MCP.DynamicSupervisor) == dynamic_supervisor
    assert :ok = Synapsis.MCP.refresh(config.id)
  end

  test "live refresh isolates an invalid stdio source while refreshing healthy sources", %{
    bypass: bypass
  } do
    suffix = System.unique_integer([:positive])

    {:ok, invalid} =
      MCPConfigs.create(%{
        name: "invalid-#{suffix}",
        transport: "stdio",
        command: "/synapsis-missing-mcp-binary"
      })

    {:ok, healthy} =
      MCPConfigs.create(%{
        name: "healthy-#{suffix}",
        transport: "streamable_http",
        url: "http://localhost:#{bypass.port}"
      })

    on_exit(fn ->
      for config <- [invalid, healthy] do
        Synapsis.MCP.stop(config.name)
        MCPConfigs.delete(config)
      end
    end)

    task_supervisor = Process.whereis(Synapsis.MCP.TaskSupervisor)
    dynamic_supervisor = Process.whereis(Synapsis.MCP.DynamicSupervisor)
    results = Synapsis.MCP.refresh_all()
    assert {:error, _} = results[invalid.id]
    assert results[healthy.id] == :ok
    assert Process.whereis(Synapsis.MCP.TaskSupervisor) == task_supervisor
    assert Process.whereis(Synapsis.MCP.DynamicSupervisor) == dynamic_supervisor
    assert Registry.runtime_available?("mcp:#{healthy.name}:echo")
  end

  test "refresh reports per-source errors when the discovery task supervisor is unavailable" do
    {:ok, config} =
      MCPConfigs.create(%{
        name: "no-tasks-#{System.unique_integer([:positive])}",
        transport: "stdio",
        command: "false"
      })

    on_exit(fn -> MCPConfigs.delete(config) end)
    task_supervisor = Process.whereis(Synapsis.MCP.TaskSupervisor)
    Process.unregister(Synapsis.MCP.TaskSupervisor)

    try do
      assert Synapsis.MCP.refresh_all()[config.id] == {:error, :mcp_refresh_unavailable}
    after
      Process.register(task_supervisor, Synapsis.MCP.TaskSupervisor)
    end
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

  test "restart attempts every identity and alias cleanup and compounds failures", %{
    bypass: bypass
  } do
    old_name = "cleanup_old_#{System.unique_integer([:positive])}"
    current_name = "cleanup_current_#{System.unique_integer([:positive])}"
    parent = self()

    {:ok, stale} =
      MCPConfigs.create(%{
        name: old_name,
        transport: "streamable_http",
        url: "http://localhost:#{bypass.port}",
        enabled: true
      })

    assert {:ok, _current} = MCPConfigs.update(stale, %{name: current_name})

    rogue_id =
      spawn(fn ->
        key = {:config_id, stale.id}
        {:ok, _value} = Elixir.Registry.register(Synapsis.MCP.Registry, key, nil)
        send(parent, {:rogue_registered, key, self()})
        receive do: (:stop -> :ok)
      end)

    rogue_old =
      spawn(fn ->
        {:ok, _value} = Elixir.Registry.register(Synapsis.MCP.Registry, old_name, nil)
        send(parent, {:rogue_registered, old_name, self()})
        receive do: (:stop -> :ok)
      end)

    current_spec = %{
      id: {:cleanup_alias, current_name},
      start: {AliasRuntime, :start_link, [current_name]},
      restart: :temporary
    }

    assert {:ok, current_pid} =
             DynamicSupervisor.start_child(Synapsis.MCP.DynamicSupervisor, current_spec)

    on_exit(fn ->
      send(rogue_id, :stop)
      send(rogue_old, :stop)

      if Process.alive?(current_pid) do
        DynamicSupervisor.terminate_child(Synapsis.MCP.DynamicSupervisor, current_pid)
      end

      if current = MCPConfigs.get(stale.id), do: MCPConfigs.delete(current)
    end)

    assert_receive {:rogue_registered, {:config_id, config_id}, ^rogue_id}
    assert config_id == stale.id
    assert_receive {:rogue_registered, ^old_name, ^rogue_old}

    assert {:error,
            {:restart_cleanup_failed,
             {:multiple_runtime_cleanup_failures,
              [
                {:runtime_stop_timeout, {:config_id, ^config_id}},
                {:runtime_stop_timeout, ^old_name}
              ]}}} = Synapsis.MCP.restart(stale)

    refute Process.alive?(current_pid)
    assert Process.alive?(rogue_id)
    assert Process.alive?(rogue_old)
    refute_receive {:mcp_request, _method}, 200
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

  test "reconciliation readiness does not permit tool execution through a durable block", %{
    bypass: bypass
  } do
    name = "blocked_reconciliation_#{System.unique_integer([:positive])}"

    {:ok, config} =
      MCPConfigs.create(%{
        name: name,
        transport: "streamable_http",
        url: "http://localhost:#{bypass.port}",
        enabled: true,
        config: %{
          "managed_by" => "backplane",
          "backplane_source_id" => "source-1",
          "backplane_available" => true,
          "backplane_tools" => [
            %{"external_id" => "echo", "backplane_available" => true}
          ]
        }
      })

    assert {:ok, _connection} =
             Store.put(:backplane, %{
               "id" => "source-1",
               "enabled" => true,
               "metadata_json" => Jason.encode!(%{"runtime_blocked_surfaces" => ["tools"]})
             })

    tool_name = "mcp:#{name}:echo"

    on_exit(fn ->
      Synapsis.MCP.stop(name)
      Registry.unregister(tool_name)
      if current = MCPConfigs.get(config.id), do: MCPConfigs.delete(current)
    end)

    refute MCPConfigs.runtime_available?(config)
    assert :ok = Synapsis.MCP.restart_for_reconciliation(config)
    assert {:ok, {:process, pid, _opts}} = Registry.lookup(tool_name)

    assert {:error, :mcp_unavailable} =
             GenServer.call(pid, {:execute, tool_name, %{}, %{}})

    refute_receive {:mcp_request, "tools/call"}, 200
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
