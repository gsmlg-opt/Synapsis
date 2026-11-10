defmodule Synapsis.Agent.Daemon.ResourceSelectionFunctionalTest do
  use Synapsis.Agent.DataCase, async: false
  @moduletag :functional

  alias Synapsis.Agent.Daemon.NativeSelection
  alias Synapsis.Agent.{Resolver, Runs}
  alias Synapsis.{AgentConfigs, MCP, MCPConfigs, Session}
  alias Synapsis.MCP.Server

  test "run captures ordered resource UUIDs independently and overlay restores them after config edits" do
    first = resource_source()
    second = resource_source()
    ids = [first.id, second.id] |> Enum.sort() |> Enum.reverse()
    names = ["clock::curr_time"]

    assert {:ok, saved} =
             AgentConfigs.create(%{
               name: unique_name(),
               tools: names,
               tool_contract_version: 1,
               config: %{
                 "mcp_resource_source_ids" => ids,
                 "mcp_selection" => %{"default" => "none", "sources" => %{}},
                 "unrelated" => %{"retained" => [2, 1]}
               }
             })

    on_exit(fn -> AgentConfigs.delete(saved) end)

    assert {:ok, captured} =
             NativeSelection.capture(%{
               tool_profile: "native_agent",
               assistant_name: saved.name
             })

    snapshot = captured.capability_snapshot
    assert snapshot["tool_names"] == names
    assert snapshot["sources"]["agent"]["mcp_resource_source_ids"] == ids
    assert {:ok, original_source} = MCP.runtime_snapshot(first.id)
    run = persist_capture(captured)

    assert {:ok, _} =
             AgentConfigs.update(saved, %{
               tools: ["synapsis::todo_read"],
               config: Map.put(saved.config, "mcp_resource_source_ids", [])
             })

    assert {:ok, live} = Resolver.resolve_configured(saved.name)
    assert live.mcp_resource_source_ids == []
    assert live.tools == ["synapsis::todo_read"]
    live = Map.put(live, :mcp_resource_sources, %{first.id => original_source})
    overlaid = NativeSelection.overlay(live, session(run))

    assert overlaid.mcp_resource_source_ids == ids
    assert Map.get(overlaid, :mcp_resource_sources, %{}) == %{}
    assert overlaid.tools == names
    assert overlaid.tool_selection_sources == snapshot["sources"]
    assert {:ok, persisted} = Runs.fetch(run.id)
    assert persisted.capability_snapshot == snapshot
    assert AgentConfigs.get(saved.id).config["unrelated"] == %{"retained" => [2, 1]}
  end

  test "historical version-one source provenance defaults resources to empty on overlay" do
    names = ["clock::curr_time"]

    assert {:ok, saved} =
             AgentConfigs.create(%{
               name: unique_name(),
               tools: names,
               tool_contract_version: 1
             })

    on_exit(fn -> AgentConfigs.delete(saved) end)

    assert {:ok, captured} =
             NativeSelection.capture(%{
               tool_profile: "native_agent",
               assistant_name: saved.name
             })

    historical =
      update_in(captured.capability_snapshot, ["sources", "agent"], fn source ->
        Map.delete(source, "mcp_resource_source_ids")
      end)

    captured = %{captured | capability_snapshot: historical}
    run = persist_capture(captured)
    assert {:ok, ^historical} = NativeSelection.snapshot(run)
    later_ids = [Ecto.UUID.generate()]

    assert {:ok, _} =
             AgentConfigs.update(saved, %{config: %{"mcp_resource_source_ids" => later_ids}})

    assert {:ok, live} = Resolver.resolve_configured(saved.name)
    assert live.mcp_resource_source_ids == later_ids
    overlaid = NativeSelection.overlay(live, session(run))
    assert overlaid.mcp_resource_source_ids == []
    assert Map.get(overlaid, :mcp_resource_sources, %{}) == %{}
    assert overlaid.tools == names
    assert {:ok, persisted} = Runs.fetch(run.id)
    assert persisted.capability_snapshot == historical
  end

  defp persist_capture(captured) do
    assert {:ok, run} =
             Runs.create(
               Map.merge(captured, %{
                 kind: "manual",
                 source: "web",
                 status: "completed",
                 session_id: Ecto.UUID.generate(),
                 prompt: "Resource selection provenance only"
               })
             )

    run
  end

  defp session(run) do
    %Session{
      id: run.session_id,
      agent: run.assistant_name,
      config: %{
        "daemon_run_id" => run.id,
        "daemon_run_tool_contract_version" => 1
      }
    }
  end

  defp resource_source do
    fixture = Gaoxy.Test.open()

    Gaoxy.Test.stub(fixture, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      result =
        case request["method"] do
          "initialize" ->
            %{
              "protocolVersion" => request["params"]["protocolVersion"],
              "capabilities" => %{"resources" => %{}},
              "serverInfo" => %{"name" => "daemon-resource-selection", "version" => "1"}
            }

          _ ->
            %{}
        end

      if Map.has_key?(request, "id") do
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
        )
      else
        Plug.Conn.resp(conn, 202, "")
      end
    end)

    for method <- ["GET", "DELETE"],
        do: Gaoxy.Test.stub(fixture, method, "/mcp", &Plug.Conn.resp(&1, 200, ""))

    assert {:ok, config} =
             MCPConfigs.create(%{
               name: "daemon-resource-#{Ecto.UUID.generate()}",
               transport: "streamable_http",
               url: String.trim_trailing(Gaoxy.Test.url(fixture), "/")
             })

    on_exit(fn -> MCPConfigs.delete(config) end)

    server =
      start_supervised!(
        Supervisor.child_spec({Server, config}, id: config.id, restart: :temporary)
      )

    assert :ok = Server.await_ready(server)
    config
  end

  defp unique_name,
    do: "daemon-resource-agent-#{System.unique_integer([:positive, :monotonic])}"
end
