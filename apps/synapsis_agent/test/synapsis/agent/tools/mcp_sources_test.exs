defmodule Synapsis.Agent.Tools.MCPSourcesTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.Tools.MCPSources
  alias Synapsis.MCP.Server
  alias Synapsis.MCPConfigs

  setup do
    fixture = Gaoxy.Test.open()
    owner = self()
    state = start_supervised!({Agent, fn -> "original" end})

    Gaoxy.Test.stub(fixture, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      result =
        case request["method"] do
          "initialize" ->
            %{
              "protocolVersion" => request["params"]["protocolVersion"],
              "capabilities" => %{"tools" => %{}},
              "serverInfo" => %{"name" => "sources", "version" => "1"}
            }

          "tools/list" ->
            %{
              "tools" =>
                for(
                  name <- ["shared", "agent-note::get_note"],
                  do: %{
                    "name" => name,
                    "description" => Agent.get(state, & &1),
                    "inputSchema" => %{
                      "type" => "object",
                      "properties" => %{},
                      "additionalProperties" => false
                    }
                  }
                )
            }

          "tools/call" ->
            send(owner, :unexpected_tool_call)
            %{"content" => []}

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

    configs =
      for n <- 1..2 do
        {:ok, config} =
          MCPConfigs.create(%{
            name: "source-#{System.unique_integer([:positive])}-#{n}",
            transport: "streamable_http",
            url: String.trim_trailing(Gaoxy.Test.url(fixture), "/")
          })

        pid =
          start_supervised!(
            Supervisor.child_spec({Server, config}, id: config.id, restart: :temporary)
          )

        assert :ok = Server.await_ready(pid)
        on_exit(fn -> MCPConfigs.delete(config) end)
        {config, pid}
      end

    [{first, first_pid}, {second, second_pid}] = configs
    %{first: first, first_pid: first_pid, second: second, second_pid: second_pid, state: state}
  end

  test "explicit empty selection remains empty and never acquires configured sources" do
    assert {:ok, %{tools: [], mcp_sources: sources}} = MCPSources.capture(%{tools: []})
    assert sources == %{}

    assert {:ok, %{tools: ["synapsis::todo_read"], mcp_sources: %{}}} =
             MCPSources.capture(%{tools: ["synapsis::todo_read"], mcp_selection: policy(%{})})

    refute_received :unexpected_tool_call
  end

  test "unresolved saved toolsets fail before source discovery or selection", ctx do
    missing = for _ <- 1..129, do: Ecto.UUID.generate()

    agent = %{
      tools: [],
      tool_selection_error: {:toolsets_unavailable, missing},
      mcp_selection: %{"default" => "all", "sources" => %{}}
    }

    assert :ok = GenServer.stop(ctx.first_pid)
    assert :ok = GenServer.stop(ctx.second_pid)

    for operation <- [&MCPSources.capture/1, &MCPSources.refresh/1] do
      assert {:error,
              %Backplane.AgentRuntime.Error{
                class: :unsupported_capability,
                details: %{toolset_ids: ^missing}
              }} = operation.(agent)
    end

    refute_received :unexpected_tool_call
  end

  @tag :contract_version
  test "resolver contract errors reject capture and refresh before selected-source discovery",
       ctx do
    {:ok, saved} =
      Synapsis.AgentConfigs.create(%{
        name: "invalid-mcp-version-#{Ecto.UUID.generate()}",
        tools: ["send_message"],
        tool_contract_version: 0,
        config: %{"mcp_selection" => policy(%{ctx.first.id => %{"mode" => "all"}})}
      })

    on_exit(fn -> Synapsis.AgentConfigs.delete(saved) end)
    agent = Synapsis.Agent.Resolver.resolve(saved.name)
    assert Map.has_key?(agent, :tool_selection_error)

    for operation <- [&MCPSources.capture/1, &MCPSources.refresh/1] do
      assert {:error, %Backplane.AgentRuntime.Error{class: :validation}} = operation.(agent)
    end

    assert {:ok, %{generation: 1}} = Server.runtime_snapshot(ctx.first_pid)
    assert {:ok, %{generation: 1}} = Server.runtime_snapshot(ctx.second_pid)
    refute_received :unexpected_tool_call
  end

  test "legacy selections retain both same-name tools using persisted source UUIDs", ctx do
    names = [
      "synapsis::todo_read",
      "mcp:#{ctx.first.name}:shared",
      "mcp:#{ctx.second.name}:shared"
    ]

    assert {:ok, agent} = MCPSources.capture(%{tools: names})

    assert agent.tools ==
             ["synapsis::todo_read", native(ctx.first, "shared"), native(ctx.second, "shared")]
             |> Enum.sort()

    assert Map.keys(agent.mcp_sources) |> Enum.sort() == Enum.sort([ctx.first.id, ctx.second.id])
    assert {:ok, revisions} = MCPSources.revisions(agent, agent.tools)
    assert revisions == Map.new(agent.tools, &{&1, 1})
    assert {:ok, source} = Synapsis.MCP.runtime_snapshot(ctx.first.id)
    assert source == agent.mcp_sources[ctx.first.id]
    refute_received :unexpected_tool_call
  end

  test "source-qualified native selection remains stable across a source rename", ctx do
    name = native(ctx.first, "agent-note::get_note")
    assert {:ok, before} = MCPSources.capture(%{tools: [name], tool_contract_version: 1})
    assert {:ok, _} = MCPConfigs.update(ctx.first, %{name: ctx.first.name <> "-renamed"})
    assert {:ok, after_rename} = MCPSources.capture(%{tools: [name], tool_contract_version: 1})
    assert before.tools == after_rename.tools
    assert before.mcp_sources == after_rename.mcp_sources
  end

  test "all selected and none policy rules use raw names including namespace separators", ctx do
    selection = %{
      tools: ["obsolete mcp name"],
      mcp_selection:
        policy(
          %{
            ctx.first.id => %{"mode" => "none"},
            ctx.second.id => %{"mode" => "selected", "tools" => ["agent-note::get_note"]}
          },
          "all"
        )
    }

    assert {:ok, agent} = MCPSources.capture(selection)

    assert agent.tools ==
             [native(ctx.second, "agent-note::get_note"), "obsolete mcp name"] |> Enum.sort()

    assert Map.keys(agent.mcp_sources) == [ctx.second.id]

    assert {:ok, all} =
             MCPSources.capture(%{
               tools: [],
               mcp_selection: policy(%{ctx.first.id => %{"mode" => "all"}})
             })

    assert Enum.sort(all.tools) ==
             Enum.sort([native(ctx.first, "shared"), native(ctx.first, "agent-note::get_note")])
  end

  test "missing selected sources and tools fail visibly without mutating saved selection", ctx do
    original = %{tools: [native(ctx.first, "missing")]}

    assert {:error, %{details: %{source_id: id, tools: ["missing"]}}} =
             MCPSources.capture(original)

    assert id == ctx.first.id
    assert original.tools == [native(ctx.first, "missing")]
    assert {:ok, _} = MCPConfigs.update(ctx.first, %{enabled: false})

    assert {:error, %{details: %{source_id: id}}} =
             MCPSources.capture(%{tools: [native(ctx.first, "shared")]})

    assert id == ctx.first.id
    foreign = Ecto.UUID.generate()

    assert {:error, _} =
             MCPSources.capture(%{
               tools: [],
               mcp_selection: policy(%{foreign => %{"mode" => "all"}})
             })

    assert {:error, _} = MCPSources.capture(%{tools: ["mcp:gone:shared"]})
    refute_received :unexpected_tool_call
  end

  test "current source generations become exact authority revisions", ctx do
    agent = %{tools: [native(ctx.first, "shared")]}
    assert {:ok, old} = MCPSources.capture(agent)
    Agent.update(ctx.state, fn _ -> "refreshed" end)
    assert :ok = Server.refresh(ctx.first_pid)
    assert {:ok, fresh} = MCPSources.capture(agent)
    assert {:ok, revisions} = MCPSources.revisions(fresh, fresh.tools)
    assert revisions[native(ctx.first, "shared")] == 2
    assert old.mcp_sources[ctx.first.id].generation == 1
    assert {:error, _} = MCPSources.revisions(%{fresh | mcp_sources: %{}}, fresh.tools)
  end

  test "refresh captures only selected sources and retains explicit empty selection", ctx do
    assert {:ok, agent} = MCPSources.refresh(%{tools: [native(ctx.first, "shared")]})
    assert agent.mcp_sources[ctx.first.id].generation == 2
    assert {:ok, %{generation: 1}} = Server.runtime_snapshot(ctx.second_pid)
    assert {:ok, %{tools: [], mcp_sources: %{}}} = MCPSources.refresh(%{tools: []})
    assert {:ok, %{generation: 2}} = Server.runtime_snapshot(ctx.first_pid)
    refute_received :unexpected_tool_call
  end

  test "malformed and ambiguous policies fail instead of becoming an empty selection", ctx do
    for invalid <- [
          nil,
          %{},
          policy(%{ctx.first.id => %{"mode" => "selected"}}),
          policy(%{ctx.first.id => %{"mode" => "selected", "tools" => ["shared", "shared"]}}),
          policy(%{"not-a-uuid" => %{"mode" => "all"}}),
          policy(%{ctx.first.id => %{"mode" => "anything"}})
        ] do
      assert {:error, _} = MCPSources.capture(%{tools: [], mcp_selection: invalid})
    end

    for tools <- [
          nil,
          ["mcp::not-a-uuid::shared"],
          [native(ctx.first, "shared"), native(ctx.first, "shared")]
        ] do
      assert {:error, _} = MCPSources.capture(%{tools: tools})
    end
  end

  test "production Profiles retains MCP revisions and unselected restrictions with exact write policy",
       ctx do
    alias Synapsis.Agent.Tools.{MCP, Policy, Profiles}
    alias Synapsis.Session.Store
    assert :ok = Server.refresh(ctx.first_pid)
    name = native(ctx.first, "shared")
    other = native(ctx.first, "agent-note::get_note")
    assert {:ok, agent} = MCPSources.capture(%{tools: [name], tool_contract_version: 1})
    session = Ecto.UUID.generate()
    on_exit(fn -> Store.delete_session(session) end)

    raw = %Synapsis.SessionPermission{
      session_id: session,
      tool_contract_version: 1,
      allow_write: :allow,
      tool_overrides: %{other => :deny}
    }

    assert :ok = Store.put_value(session, "permission", raw)

    identity = %{
      caller: "mcp-profile",
      session_id: session,
      run_id: "opaque / run",
      incarnation: 1,
      catalog_revision: 1
    }

    context = %{agent: agent, session: %{id: session, config: %{"subagents" => false}}}
    assert {:ok, revisions} = MCPSources.revisions(agent, agent.tools)

    ceiling = %{
      caller: identity.caller,
      run_id: identity.run_id,
      grants: agent.tools,
      tool_revisions: revisions
    }

    assert {:ok, %{bundle: bundle, snapshot: snapshot}} =
             Profiles.build(context, identity, [], ceiling)

    assert Map.keys(bundle.registry.tools) == [name]
    descriptor = bundle.registry.tools[name]
    assert descriptor.backend == MCP
    assert descriptor.tool_revision == 2

    assert descriptor.schema == %{
             "type" => "object",
             "properties" => %{},
             "additionalProperties" => false
           }

    assert snapshot.permission_levels[name] == :write
    assert Map.has_key?(snapshot.known_bindings, other)

    invocation =
      Map.merge(Map.take(identity, [:run_id, :incarnation, :catalog_revision]), %{
        tool_name: name,
        tool_revision: 2,
        arguments: %{}
      })

    assert {:ok, sidecars} = Profiles.prepare_context(invocation, snapshot)
    assert :allow = Policy.prepare_tool(invocation, Map.put(sidecars, :input_kind, :function))
    assert :ok = Store.put_value(session, "permission", %{raw | allow_write: :deny})
    assert {:ok, %{snapshot: denied}} = Profiles.build(context, identity, [], ceiling)
    assert {:ok, sidecars} = Profiles.prepare_context(invocation, denied)

    assert {:deny, :policy_denied} =
             Policy.prepare_tool(invocation, Map.put(sidecars, :input_kind, :function))
  end

  defp policy(sources, default \\ "selected"), do: %{"default" => default, "sources" => sources}
  defp native(config, raw), do: "mcp::#{config.id}::#{raw}"
end
