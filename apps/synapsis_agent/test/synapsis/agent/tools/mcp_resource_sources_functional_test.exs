defmodule Synapsis.Agent.Tools.MCPResourceSourcesFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Agent.Tools.MCPSources
  alias Synapsis.{MCP, MCPConfigs}
  alias Synapsis.MCP.Server

  test "resource-only sources retain configured order and exact independent snapshots" do
    first = source(false)
    second = source(false)
    ids = [first.config.id, second.config.id] |> Enum.sort() |> Enum.reverse()
    names = ["clock::curr_time"]

    agent = %{
      tools: names,
      mcp_selection: policy(%{}),
      mcp_resource_source_ids: ids
    }

    expected = snapshots(ids)
    assert {:ok, captured} = MCPSources.capture(agent)
    assert captured.mcp_resource_source_ids == ids
    assert captured.mcp_resource_sources == expected
    assert captured.mcp_sources == %{}
    assert captured.tools == names

    assert {:ok, refreshed} = MCPSources.refresh(agent)
    assert refreshed.mcp_resource_source_ids == ids
    assert refreshed.mcp_resource_sources == snapshots(ids)
    assert refreshed.mcp_sources == %{}
    assert refreshed.tools == names

    for id <- ids do
      assert refreshed.mcp_resource_sources[id].generation == expected[id].generation + 1
      assert refreshed.mcp_resource_sources[id].tools == []
    end

    assert methods(first) == ["initialize", "notifications/initialized"]
    assert methods(second) == ["initialize", "notifications/initialized"]
  end

  test "tool-selected source has empty resource selection unless selected independently" do
    selected = source(true)
    id = selected.config.id
    name = "mcp::#{id}::selected"

    assert {:ok, captured} =
             MCPSources.capture(%{
               tools: ["clock::curr_time"],
               mcp_selection: policy(%{id => %{"mode" => "all"}})
             })

    assert {:ok, snapshot} = MCP.runtime_snapshot(id)
    assert captured.mcp_resource_source_ids == []
    assert captured.mcp_resource_sources == %{}
    assert captured.mcp_sources == %{id => snapshot}
    assert captured.tools == Enum.sort(["clock::curr_time", name])
    assert methods(selected) == ["initialize", "notifications/initialized", "tools/list"]
  end

  test "one source selected for tools and resources refreshes once before both captures" do
    selected = source(true)
    id = selected.config.id
    assert {:ok, before} = MCP.runtime_snapshot(id)
    before_lists = Enum.count(methods(selected), &(&1 == "tools/list"))

    assert {:ok, refreshed} =
             MCPSources.refresh(%{
               tools: ["clock::curr_time"],
               mcp_selection: policy(%{id => %{"mode" => "all"}}),
               mcp_resource_source_ids: [id]
             })

    assert {:ok, current} = MCP.runtime_snapshot(id)
    assert current.generation == before.generation + 1
    assert refreshed.mcp_resource_source_ids == [id]
    assert refreshed.mcp_resource_sources == %{id => current}
    assert refreshed.mcp_sources == %{id => current}
    assert refreshed.tools == Enum.sort(["clock::curr_time", "mcp::#{id}::selected"])
    assert Enum.count(methods(selected), &(&1 == "tools/list")) == before_lists + 1

    assert Enum.all?(methods(selected), fn method ->
             method in ["initialize", "notifications/initialized", "tools/list"]
           end)
  end

  defp snapshots(ids) do
    Map.new(ids, fn id ->
      assert {:ok, snapshot} = MCP.runtime_snapshot(id)
      {id, snapshot}
    end)
  end

  defp policy(sources), do: %{"default" => "none", "sources" => sources}

  defp methods(source), do: Agent.get(source.calls, &Enum.map(&1, fn call -> call["method"] end))

  defp source(tools?) do
    fixture = Gaoxy.Test.open()

    calls =
      start_supervised!(Supervisor.child_spec({Agent, fn -> [] end}, id: make_ref()))

    Gaoxy.Test.stub(fixture, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      Agent.update(calls, &(&1 ++ [request]))

      result =
        case request["method"] do
          "initialize" ->
            capabilities = %{"resources" => %{}}
            capabilities = if tools?, do: Map.put(capabilities, "tools", %{}), else: capabilities

            %{
              "protocolVersion" => request["params"]["protocolVersion"],
              "capabilities" => capabilities,
              "serverInfo" => %{"name" => "resource-selection", "version" => "1"}
            }

          "tools/list" ->
            %{
              "tools" => [
                %{
                  "name" => "selected",
                  "description" => "Ordinary selected tool",
                  "inputSchema" => %{
                    "type" => "object",
                    "properties" => %{},
                    "additionalProperties" => false
                  }
                }
              ]
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
               name: "resource-source-#{Ecto.UUID.generate()}",
               transport: "streamable_http",
               url: String.trim_trailing(Gaoxy.Test.url(fixture), "/")
             })

    on_exit(fn -> MCPConfigs.delete(config) end)

    server =
      start_supervised!(
        Supervisor.child_spec({Server, config}, id: config.id, restart: :temporary)
      )

    assert :ok = Server.await_ready(server)
    %{config: config, calls: calls}
  end
end
