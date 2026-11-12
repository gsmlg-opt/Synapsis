defmodule Synapsis.MCPTest do
  use ExUnit.Case, async: false

  alias Synapsis.Config.Store
  alias Synapsis.MCPConfig
  alias Synapsis.MCPConfigs

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

    bypass = Gaoxy.Test.open()
    test_pid = self()

    Gaoxy.Test.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      send(test_pid, {:mcp_request, request["method"]})
      handle(conn, request)
    end)

    Gaoxy.Test.stub(bypass, "GET", "/mcp", fn conn -> Plug.Conn.resp(conn, 200, "") end)
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

  test "a failed client stops its runtime without restarting unrelated MCP infrastructure", %{
    bypass: bypass
  } do
    name = "failed-client-#{System.unique_integer([:positive])}"

    {:ok, config} =
      MCPConfigs.create(%{
        name: name,
        transport: "streamable_http",
        url: String.trim_trailing(Gaoxy.Test.url(bypass), "/")
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

  test "refresh reconnects a source whose initial negotiation failed once it is reachable" do
    bypass = Gaoxy.Test.open()
    {:ok, health} = Agent.start_link(fn -> :down end)

    Gaoxy.Test.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case Agent.get(health, & &1) do
        # A gateway mid-reload answers with an HTML error page.
        :down -> Plug.Conn.resp(conn, 500, "<html>CompileError</html>")
        :up -> handle(conn, Jason.decode!(body))
      end
    end)

    Gaoxy.Test.stub(bypass, "GET", "/mcp", fn conn -> Plug.Conn.resp(conn, 200, "") end)
    name = "renegotiate-#{System.unique_integer([:positive])}"

    {:ok, config} =
      MCPConfigs.create(%{
        name: name,
        transport: "streamable_http",
        url: String.trim_trailing(Gaoxy.Test.url(bypass), "/")
      })

    on_exit(fn ->
      Synapsis.MCP.stop(name)
      MCPConfigs.delete(config)
    end)

    {:ok, server} = Synapsis.MCP.start(config)
    assert {:error, _reason} = Synapsis.MCP.Server.await_ready(server)
    assert {:error, _reason} = Synapsis.MCP.refresh(config.id)

    Agent.update(health, fn _ -> :up end)
    assert :ok = Synapsis.MCP.refresh(config.id)
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
      url: String.trim_trailing(Gaoxy.Test.url(bypass), "/")
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
        url: String.trim_trailing(Gaoxy.Test.url(bypass), "/"),
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

  test "restart rejects a stale enabled struct after its persisted record is disabled", %{
    bypass: bypass
  } do
    name = "stale_disabled_#{System.unique_integer([:positive])}"

    {:ok, stale} =
      MCPConfigs.create(%{
        name: name,
        transport: "streamable_http",
        url: String.trim_trailing(Gaoxy.Test.url(bypass), "/"),
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
        url: String.trim_trailing(Gaoxy.Test.url(bypass), "/"),
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
