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

  test "native runtime dispatch normalizes results and rejects undiscovered tools", %{
    bypass: bypass
  } do
    {server, echo, _pending} = runtime_server(bypass)
    assert {:ok, {:process, ^server, opts}} = Registry.lookup(echo)
    assert opts[:runtime_dispatch] == Server

    assert {:ok, "native result"} =
             Server.execute_runtime(server, echo, %{"text" => "native result"}, %{}, 1_000)

    assert {:error, :mcp_unavailable} =
             Server.execute_runtime(server, echo <> "-unknown", %{}, %{}, 1_000)
  end

  test "native timeout cancels only its owned request and keeps the server responsive", %{
    bypass: bypass
  } do
    {server, echo, pending} = runtime_server(bypass)

    task = Task.async(fn -> Server.execute_runtime(server, pending, %{}, %{}, 500) end)
    assert_receive {:mcp_tool_pending, request_id}, 2_000
    assert :ok = Server.await_ready(server, 200)

    assert {:ok, "sibling result"} =
             Server.execute_runtime(server, echo, %{"text" => "sibling result"}, %{}, 1_000)

    assert {:error, :timeout} = Task.await(task, 2_000)

    assert_receive {:mcp_tool_cancelled,
                    %{"requestId" => ^request_id, "reason" => "tool_timeout"}},
                   2_000

    assert Process.alive?(server)
  end

  test "native effect owner death cancels its request without stopping sibling calls", %{
    bypass: bypass
  } do
    {server, echo, pending} = runtime_server(bypass)
    tasks = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(tasks, fn ->
        Server.execute_runtime(server, pending, %{}, %{}, 5_000)
      end)

    assert_receive {:mcp_tool_pending, request_id}, 2_000
    Task.shutdown(task, :brutal_kill)

    assert_receive {:mcp_tool_cancelled, %{"requestId" => ^request_id, "reason" => "owner_down"}},
                   2_000

    assert {:ok, "surviving result"} =
             Server.execute_runtime(server, echo, %{"text" => "surviving result"}, %{}, 1_000)

    assert Process.alive?(server)
  end

  test "revokes trusted MCP read-only admission live when source trust is removed", %{
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

    stub_mcp(bypass, name, self(), tools)

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
    assert Registry.runtime_available?(tool)
    assert [%{name: ^tool}] = Registry.list_for_query_loop(names: [tool])

    context = %{run_id: Ecto.UUID.generate(), permission_mode: "auto"}
    assert {:ok, snapshot} = Synapsis.Tool.Gateway.resolve_snapshot(context)
    assert {:ok, grant} = Synapsis.Tool.Gateway.authorize(tool, %{}, snapshot, context)
    authorized_context = Map.put(context, :capability_grant, grant)

    assert {:ok, revoked_source} =
             Store.merge_existing(:backplane, source_id, %{
               "connection_options_json" => Jason.encode!(%{"trust_mcp_annotations" => false})
             })

    assert revoked_source["enabled"] == true
    assert Process.alive?(pid)
    assert {:ok, {:process, ^pid, _opts}} = Registry.lookup(tool)
    refute MCPConfigs.trust_tool_annotations?(MCPConfigs.get(config.id))
    refute Registry.runtime_available?(tool)

    # Daemon Toolsets select MCP candidates through this runtime-filtered registry view.
    assert [] = Registry.list_for_query_loop(names: [tool])

    assert {:error, :tool_disabled} =
             Synapsis.Tool.Executor.execute_approved(tool, %{}, authorized_context)

    assert {:error, :mcp_unavailable} =
             GenServer.call(pid, {:execute, tool, %{"text" => "blocked"}, %{}}, 10_000)

    assert {:error, :mcp_unavailable} =
             Server.execute_runtime(pid, tool, %{"text" => "blocked"}, %{}, 1_000)

    refute_receive {:mcp_tool_called, _params}, 100
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
    refute Registry.runtime_available?(tool)
    assert [] = Registry.list_for_query_loop(names: [tool])

    assert {:error, :mcp_unavailable} =
             GenServer.call(pid, {:execute, tool, %{"text" => "blocked"}, %{}}, 10_000)

    refute_receive {:mcp_tool_called, _params}, 100
  end

  test "live catalog includes newly discovered tools absent from persisted Backplane metadata", %{
    bypass: bypass
  } do
    name = "new_tools_#{System.unique_integer([:positive])}"
    stub_mcp(bypass, name, nil, [%{"name" => "fresh"}])

    {:ok, config} =
      MCPConfigs.create(%{
        name: name,
        transport: "streamable_http",
        url: "http://localhost:#{bypass.port}",
        config: %{
          "managed_by" => "backplane",
          "backplane_source_id" => "source-1",
          "backplane_available" => true,
          "backplane_tools" => []
        }
      })

    on_exit(fn -> if current = MCPConfigs.get(config.id), do: MCPConfigs.delete(current) end)
    server = start_supervised!({Server, config})
    assert :ok = Server.await_ready(server)
    assert {:ok, {:process, ^server, opts}} = Registry.lookup("mcp:#{name}:fresh")
    assert opts[:mcp_config_id] == config.id
    assert opts[:mcp_tool_name] == "fresh"
  end

  test "live refresh replaces the complete paginated catalog and rejects failed refresh catalogs",
       %{bypass: bypass} do
    name = "live_#{System.unique_integer([:positive])}"
    {:ok, mode} = Agent.start_link(fn -> :initial end)
    on_exit(fn -> if Process.alive?(mode), do: Agent.stop(mode) end)

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      result =
        case request["method"] do
          "initialize" ->
            %{
              "protocolVersion" => request["params"]["protocolVersion"],
              "capabilities" => %{"tools" => %{}},
              "serverInfo" => %{"name" => name, "version" => "1"}
            }

          "tools/list" ->
            case {Agent.get(mode, & &1), get_in(request, ["params", "cursor"])} do
              {:initial, _} -> %{"tools" => [%{"name" => "old"}]}
              {:updated, nil} -> %{"tools" => [%{"name" => "new"}], "nextCursor" => "page2"}
              {:updated, "page2"} -> %{"tools" => [%{"name" => "last"}]}
              {:cycle, _} -> %{"tools" => [%{"name" => "partial"}], "nextCursor" => "repeat"}
            end

          _ ->
            %{}
        end

      if request["id"],
        do:
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
          ),
        else: Plug.Conn.resp(conn, 202, "")
    end)

    Bypass.stub(bypass, "GET", "/mcp", &Plug.Conn.resp(&1, 200, ""))
    Bypass.stub(bypass, "DELETE", "/mcp", &Plug.Conn.resp(&1, 200, ""))

    server =
      start_supervised!(
        {Server,
         %MCPConfig{
           name: name,
           transport: "streamable_http",
           url: "http://localhost:#{bypass.port}"
         }}
      )

    assert :ok = Server.await_ready(server)
    assert {:ok, _} = Registry.lookup("mcp:#{name}:old")
    Agent.update(mode, fn _ -> :updated end)
    assert :ok = Server.refresh(server)
    assert {:error, :not_found} = Registry.lookup("mcp:#{name}:old")
    assert {:ok, {:process, ^server, opts}} = Registry.lookup("mcp:#{name}:last")
    assert opts[:mcp_tool_name] == "last"
    Agent.update(mode, fn _ -> :cycle end)
    assert {:error, :mcp_cursor_cycle} = Server.refresh(server)
    refute Registry.runtime_available?("mcp:#{name}:last")
    assert {:error, :not_found} = Registry.lookup("mcp:#{name}:partial")

    assert {:error, :mcp_unavailable} =
             Server.execute_runtime(server, "mcp:#{name}:last", %{}, %{}, 1_000)

    assert Process.alive?(server)
  end

  test "linked MCP reconnects with current credentials and rejects old credentials immediately",
       %{bypass: bypass} do
    name = "linked-mcp-#{System.unique_integer([:positive])}"

    {:ok, provider} =
      Synapsis.Providers.create(%{
        name: name,
        type: "openai",
        base_url: "http://localhost:#{bypass.port}/v1",
        api_key_encrypted: "first",
        config: %{"preset" => "backplane"}
      })

    {:ok, config} =
      Synapsis.Backplane.select_mcp_provider(provider.id, "http://localhost:#{bypass.port}/mcp")

    {:ok, expected} = Agent.start_link(fn -> "first" end)
    stub_mcp(bypass, config.name)

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == [
               "Bearer " <> Agent.get(expected, & &1)
             ]

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      handle_rpc(conn, Jason.decode!(body), config.name, nil, [%{"name" => "echo"}])
    end)

    on_exit(fn ->
      Synapsis.MCP.stop(config.name)
      if Process.alive?(expected), do: Agent.stop(expected)
      MCPConfigs.delete(config)

      for source <- Synapsis.Backplane.Connection.list(),
          source.provider_id == provider.id,
          do: Synapsis.Backplane.Connection.delete(source)

      Synapsis.Providers.delete(provider.id)
    end)

    assert {:ok, server} = Synapsis.MCP.start(config)
    assert :ok = Server.await_ready(server)
    tool = "mcp:#{config.name}:echo"
    Agent.update(expected, fn _ -> "rotated" end)
    {:ok, _} = Synapsis.Providers.update(provider.id, %{api_key_encrypted: "rotated"})
    refute Process.alive?(server)
    assert {:error, :mcp_unavailable} = Server.execute_runtime(server, tool, %{}, %{}, 1_000)
    assert :ok = Synapsis.MCP.refresh(config.id)
    assert Registry.runtime_available?(tool)
    {:ok, _} = Synapsis.Providers.update(provider.id, %{enabled: false})
    refute Registry.runtime_available?(tool)
    {:ok, _} = Synapsis.Providers.update(provider.id, %{enabled: true})
    refute Registry.runtime_available?(tool)
    assert :ok = Synapsis.MCP.refresh(config.id)
    assert Registry.runtime_available?(tool)
    {:ok, _} = Synapsis.Providers.update(provider.id, %{enabled: false})
    assert {:error, :mcp_unavailable} = Synapsis.MCP.refresh(config.id)
  end

  test "concurrent live refreshes coalesce and caller timeout leaves another caller intact", %{
    bypass: bypass
  } do
    name = "coalesced-#{System.unique_integer([:positive])}"
    observer = self()
    {:ok, blocked} = Agent.start_link(fn -> false end)
    on_exit(fn -> if Process.alive?(blocked), do: Agent.stop(blocked) end)
    stub_mcp(bypass, name)

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      if request["method"] == "tools/list" and Agent.get(blocked, & &1) do
        send(observer, {:live_page_started, self()})

        receive do
          :release -> :ok
        after
          2_000 -> :ok
        end
      end

      handle_rpc(conn, request, name, nil, [%{"name" => "echo"}])
    end)

    server =
      start_supervised!(
        {Server,
         %MCPConfig{
           name: name,
           transport: "streamable_http",
           url: "http://localhost:#{bypass.port}"
         }}
      )

    assert :ok = Server.await_ready(server)
    Agent.update(blocked, fn _ -> true end)
    caller = Task.async(fn -> Server.refresh(server, 2_000) end)
    assert_receive {:live_page_started, page}
    assert Registry.runtime_available?("mcp:#{name}:echo")
    assert {:error, :mcp_ready_timeout} = Server.refresh(server, 30)
    assert :ok = Server.await_ready(server, 100)
    refute_receive {:live_page_started, _}, 50
    send(page, :release)
    assert :ok = Task.await(caller, 2_000)
    assert Registry.runtime_available?("mcp:#{name}:echo")
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

  defp runtime_server(bypass) do
    name = "runtime_#{System.unique_integer([:positive])}"

    tools =
      Enum.map(["echo", "pending"], fn name ->
        %{"name" => name, "inputSchema" => %{"type" => "object"}}
      end)

    stub_mcp(bypass, name, self(), tools)

    server =
      start_supervised!(
        {Server,
         %MCPConfig{
           name: name,
           transport: "streamable_http",
           url: "http://localhost:#{bypass.port}"
         }}
      )

    assert :ok = Server.await_ready(server)
    {server, "mcp:#{name}:echo", "mcp:#{name}:pending"}
  end
end
