defmodule Synapsis.Agent.DaemonNativeMCPFunctionalTest do
  use Synapsis.Agent.DaemonCase, async: false
  @moduletag :functional
  alias Synapsis.Agent.DaemonNativeFunctionalTest, as: Native
  alias Synapsis.MCP.Server
  alias Synapsis.Part.ToolResult

  @moduletag :tmp_dir
  test "captured all-source selection stays frozen when turn discovery adds a tool", ctx do
    owner = self()
    fixture = Gaoxy.Test.open()
    state = start_supervised!({Agent, fn -> %{lists: 0, calls: []} end})

    Gaoxy.Test.stub(fixture, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      result =
        case request["method"] do
          "initialize" ->
            %{
              "protocolVersion" => request["params"]["protocolVersion"],
              "capabilities" => %{"tools" => %{}},
              "serverInfo" => %{"name" => "native-daemon", "version" => "1"}
            }

          "tools/list" ->
            index = Agent.get_and_update(state, &{&1.lists, %{&1 | lists: &1.lists + 1}})
            send(owner, {:native_source_list, index})
            names = if index == 0, do: ["selected"], else: ["selected", "added_later"]

            %{
              "tools" =>
                Enum.map(
                  names,
                  &%{
                    "name" => &1,
                    "description" => "Local selected source",
                    "inputSchema" => %{
                      "type" => "object",
                      "properties" => %{},
                      "additionalProperties" => false
                    },
                    "annotations" => %{"readOnlyHint" => true}
                  }
                )
            }

          "tools/call" ->
            Agent.update(state, &%{&1 | calls: &1.calls ++ [request["params"]]})

            %{
              "content" => [%{"type" => "text", "text" => "one local effect"}],
              "isError" => false
            }

          _ ->
            %{}
        end

      if Map.has_key?(request, "id"),
        do:
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
          ),
        else: Plug.Conn.resp(conn, 202, "")
    end)

    for method <- ["GET", "DELETE"],
        do: Gaoxy.Test.stub(fixture, method, "/mcp", &Plug.Conn.resp(&1, 200, ""))

    assert {:ok, source} =
             Synapsis.MCPConfigs.create(%{
               name: "daemon-mcp-#{Ecto.UUID.generate()}",
               transport: "streamable_http",
               url: String.trim_trailing(Gaoxy.Test.url(fixture), "/")
             })

    on_exit(fn -> Synapsis.MCPConfigs.delete(source) end)
    pid = start_supervised!(Supervisor.child_spec({Server, source}, restart: :temporary))
    assert :ok = Server.await_ready(pid)
    assert_receive {:native_source_list, 0}, 5_000
    policy = %{"default" => "none", "sources" => %{source.id => %{"mode" => "all"}}}

    {saved, provider} =
      Native.native_agent(ctx.tmp_dir, [], %{
        config: %{"workspace_path" => ctx.tmp_dir, "mcp_selection" => policy}
      })

    name = "mcp::#{source.id}::selected"
    Native.install_provider(provider, name)
    {daemon, _} = start_test_daemon()
    assert {:ok, queued} = Daemon.submit(daemon, "Use captured source", Native.native_opts(saved))
    assert queued.capability_snapshot["tool_names"] == [name]
    assert queued.capability_snapshot["sources"]["agent"]["mcp_selection"] == policy
    assert {:ok, completed} = wait_for_run(queued.id, "completed")
    assert_receive {:native_source_list, 1}, 5_000
    assert_receive {:native_request, 0, first}, 5_000
    assert Native.tool_names(first) == [Synapsis.Provider.ToolName.encode(name)]
    assert_receive {:native_request, 1, following}, 5_000

    assert [%ToolResult{is_error: false} = result] =
             Native.parts(completed.session_id, ToolResult)

    Native.assert_wire_result(following, result)
    assert Agent.get(state, & &1.calls) == [%{"name" => "selected", "arguments" => %{}}]
    assert {:ok, turns} = Synapsis.Session.Store.list_turns(completed.session_id)

    assert Enum.any?(
             for(turn <- turns, part <- turn.parts, do: part),
             &(&1[:type] == "tool_result" and &1[:content] == result.content)
           )

    assert completed.capability_snapshot == queued.capability_snapshot
  end
end
