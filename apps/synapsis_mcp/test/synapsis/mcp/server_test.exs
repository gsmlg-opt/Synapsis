defmodule Synapsis.MCP.ServerTest do
  use ExUnit.Case, async: false

  alias Synapsis.Config.Store
  alias Synapsis.MCP.Server
  alias Synapsis.MCPConfig
  alias Synapsis.MCPConfigs
  alias Synapsis.Tool.Registry

  setup do
    Synapsis.DataCase.clear_config_store(:backplane)

    assert {:ok, _connection} =
             Store.put(:backplane, %{"id" => "source-1", "enabled" => true})

    on_exit(fn -> Synapsis.DataCase.clear_config_store(:backplane) end)

    bypass = Bypass.open()
    {:ok, bypass: bypass}
  end

  defp stub_mcp(bypass, server_name, call_observer \\ nil, tools \\ nil) do
    tools =
      tools ||
        [
          %{"name" => "echo", "description" => "e", "inputSchema" => %{"type" => "object"}}
        ]

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      req = Jason.decode!(body)
      handle_rpc(conn, req, server_name, call_observer, tools)
    end)

    # tolerate any other requests the MCP client makes (GET sse channel, etc.)
    Bypass.stub(bypass, "GET", "/mcp", fn conn ->
      Plug.Conn.resp(conn, 200, "")
    end)

    Bypass.stub(bypass, "DELETE", "/mcp", fn conn ->
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
          %{"content" => [%{"type" => "text", "text" => req["params"]["arguments"]["text"]}]}

        _ ->
          %{}
      end

    conn
    |> Plug.Conn.put_resp_header("content-type", "application/json")
    |> Plug.Conn.resp(200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}))
  end

  defp handle_rpc(conn, _notification, _server_name, _call_observer, _tools) do
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

  test "preserves untrusted MCP annotations without downgrading permission", %{bypass: bypass} do
    name = "metadata_#{System.unique_integer([:positive])}"

    tools = [
      %{
        "name" => "read_notes",
        "annotations" => %{"readOnlyHint" => true, "openWorldHint" => false}
      },
      %{
        "name" => "delete_note",
        "annotations" => %{"readOnlyHint" => true, "destructiveHint" => true}
      },
      %{"name" => "unannotated"}
    ]

    stub_mcp(bypass, name, nil, tools)

    pid =
      start_supervised!(
        {Server,
         %MCPConfig{
           name: name,
           transport: "streamable_http",
           url: "http://localhost:#{bypass.port}"
         }}
      )

    assert wait_until(fn ->
             match?({:ok, {:process, ^pid, _opts}}, Registry.lookup("mcp:#{name}:read_notes"))
           end)

    assert {:ok, {:process, ^pid, read_opts}} = Registry.lookup("mcp:#{name}:read_notes")
    assert read_opts[:category] == :mcp
    assert read_opts[:permission_level] == :write
    assert read_opts[:trust_annotations] == false
    assert read_opts[:annotations] == %{"readOnlyHint" => true, "openWorldHint" => false}

    assert {:ok, {:process, ^pid, destructive_opts}} =
             Registry.lookup("mcp:#{name}:delete_note")

    assert destructive_opts[:permission_level] == :write

    assert {:ok, {:process, ^pid, unannotated_opts}} =
             Registry.lookup("mcp:#{name}:unannotated")

    assert unannotated_opts[:permission_level] == :write
  end

  test "uses MCP read-only annotations only for an explicitly trusted Backplane source", %{
    bypass: bypass
  } do
    source_id = Ecto.UUID.generate()
    name = "trusted_metadata_#{System.unique_integer([:positive])}"

    assert {:ok, _connection} =
             Store.put(:backplane, %{
               "id" => source_id,
               "enabled" => true,
               "connection_options_json" => Jason.encode!(%{"trust_mcp_annotations" => true})
             })

    tools = [
      %{
        "name" => "read_notes",
        "annotations" => %{"readOnlyHint" => true, "destructiveHint" => false}
      }
    ]

    stub_mcp(bypass, name, nil, tools)

    {:ok, config} =
      MCPConfigs.create(%{
        name: name,
        transport: "streamable_http",
        url: "http://localhost:#{bypass.port}",
        config: %{
          "managed_by" => "backplane",
          "backplane_source_id" => source_id,
          "backplane_available" => true,
          "backplane_tools" => [
            %{"external_id" => "read_notes", "backplane_available" => true}
          ]
        }
      })

    on_exit(fn ->
      if current = MCPConfigs.get(config.id), do: MCPConfigs.delete(current)
      Store.delete(:backplane, source_id)
    end)

    pid = start_supervised!({Server, config})
    tool = "mcp:#{name}:read_notes"

    assert wait_until(fn -> match?({:ok, {:process, ^pid, _opts}}, Registry.lookup(tool)) end)
    assert {:ok, {:process, ^pid, opts}} = Registry.lookup(tool)
    assert opts[:permission_level] == :read
    assert opts[:trust_annotations] == true
  end

  test "re-registers discovered tools after tool registry restart", %{bypass: bypass} do
    name = "srv_#{System.unique_integer([:positive])}"
    stub_mcp(bypass, name)

    cfg = %MCPConfig{
      name: name,
      transport: "streamable_http",
      url: "http://localhost:#{bypass.port}"
    }

    {:ok, pid} = Server.start_link(cfg)

    tool = "mcp:#{name}:echo"
    assert wait_until(fn -> match?({:ok, {:process, ^pid, _opts}}, Registry.lookup(tool)) end)

    :ok = Supervisor.terminate_child(SynapsisCore.Supervisor, Synapsis.Tool.Registry)
    {:ok, _pid} = Supervisor.restart_child(SynapsisCore.Supervisor, Synapsis.Tool.Registry)

    assert wait_until(fn -> match?({:ok, {:process, ^pid, _opts}}, Registry.lookup(tool)) end)

    GenServer.stop(pid)
    assert wait_until(fn -> match?({:error, :not_found}, Registry.lookup(tool)) end)
  end

  test "an old server terminate callback preserves a replacement tool owner" do
    test_pid = self()
    tool = "mcp:replacement:echo-#{System.unique_integer([:positive])}"

    old_owner =
      spawn(fn ->
        :ok = Registry.register_process(tool, self(), description: "old", parameters: %{})
        send(test_pid, {:old_owner_ready, self()})

        receive do
          :terminate ->
            :ok = Server.terminate(:normal, %{tool_names: [tool]})
            send(test_pid, :old_owner_terminated)
        end
      end)

    new_owner = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn ->
      if Process.alive?(old_owner), do: Process.exit(old_owner, :kill)
      Process.exit(new_owner, :kill)
      Registry.unregister(tool)
    end)

    assert_receive {:old_owner_ready, ^old_owner}
    :ok = Registry.register_process(tool, new_owner, description: "new", parameters: %{})

    send(old_owner, :terminate)
    assert_receive :old_owner_terminated
    assert {:ok, {:process, ^new_owner, _opts}} = Registry.lookup(tool)
  end

  test "rejects execution when the persisted config becomes runtime-unavailable", %{
    bypass: bypass
  } do
    name = "stale_#{System.unique_integer([:positive])}"
    stub_mcp(bypass, name, self())

    source_config = %{
      "managed_by" => "backplane",
      "backplane_source_id" => "source-1",
      "backplane_available" => true,
      "backplane_tools" => [%{"external_id" => "echo", "backplane_available" => true}]
    }

    {:ok, config} =
      MCPConfigs.create(%{
        name: name,
        transport: "streamable_http",
        url: "http://localhost:#{bypass.port}",
        config: source_config
      })

    pid = start_supervised!({Server, config})

    on_exit(fn ->
      if current = MCPConfigs.get(config.id), do: MCPConfigs.delete(current)
    end)

    tool = "mcp:#{name}:echo"
    assert wait_until(fn -> match?({:ok, {:process, ^pid, _opts}}, Registry.lookup(tool)) end)

    assert {:ok, unavailable} =
             MCPConfigs.update(config, %{
               config: Map.put(source_config, "backplane_available", false)
             })

    refute MCPConfigs.runtime_available?(unavailable)

    assert {:error, :mcp_unavailable} =
             GenServer.call(pid, {:execute, tool, %{"text" => "blocked"}, %{}}, 10_000)

    refute_receive {:mcp_tool_called, _params}, 100
  end

  test "registers and executes only available tools for a source-managed config", %{
    bypass: bypass
  } do
    name = "mixed_#{System.unique_integer([:positive])}"

    tools = [
      %{"name" => "enabled::tool", "description" => "enabled", "inputSchema" => %{}},
      %{"name" => "disabled::tool", "description" => "disabled", "inputSchema" => %{}}
    ]

    stub_mcp(bypass, name, self(), tools)

    {:ok, config} =
      MCPConfigs.create(%{
        name: name,
        transport: "streamable_http",
        url: "http://localhost:#{bypass.port}",
        config: %{
          "managed_by" => "backplane",
          "backplane_source_id" => "source-1",
          "backplane_available" => true,
          "backplane_tools" => [
            %{"external_id" => "enabled::tool", "backplane_available" => true},
            %{"external_id" => "disabled::tool", "backplane_available" => false}
          ]
        }
      })

    on_exit(fn ->
      if current = MCPConfigs.get(config.id), do: MCPConfigs.delete(current)
    end)

    pid = start_supervised!({Server, config})
    enabled_tool = "mcp:#{name}:enabled::tool"
    disabled_tool = "mcp:#{name}:disabled::tool"

    assert wait_until(fn ->
             match?({:ok, {:process, ^pid, _opts}}, Registry.lookup(enabled_tool))
           end)

    assert {:error, :not_found} = Registry.lookup(disabled_tool)

    assert {:ok, "allowed"} =
             GenServer.call(pid, {:execute, enabled_tool, %{"text" => "allowed"}, %{}}, 10_000)

    assert_receive {:mcp_tool_called, %{"name" => "enabled::tool"}}

    assert {:error, :mcp_unavailable} =
             GenServer.call(pid, {:execute, disabled_tool, %{"text" => "blocked"}, %{}}, 10_000)

    refute_receive {:mcp_tool_called, %{"name" => "disabled::tool"}}, 100

    markers =
      Enum.map(config.config["backplane_tools"], fn
        %{"external_id" => "enabled::tool"} = marker ->
          Map.put(marker, "backplane_available", false)

        marker ->
          marker
      end)

    assert {:ok, _current} =
             MCPConfigs.update(config, %{
               config: Map.put(config.config, "backplane_tools", markers)
             })

    assert {:error, :mcp_unavailable} =
             GenServer.call(pid, {:execute, enabled_tool, %{"text" => "stale"}, %{}}, 10_000)

    refute_receive {:mcp_tool_called, %{"name" => "enabled::tool"}}, 100
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
