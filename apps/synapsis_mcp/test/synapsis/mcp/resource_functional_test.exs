defmodule Synapsis.MCP.ResourceFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Backplane.McpProtocol.Client
  alias Synapsis.MCP
  alias Synapsis.MCP.Server
  alias Synapsis.MCPConfigs

  @uri "fixture://資料/音声と本文"
  @cursor "次の頁/opaque+cursor=="
  @template_cursor "型/続き"
  @request_meta %{"fixture/request" => %{"label" => "原文", "order" => [2, 1]}}
  @first_page %{
    "resources" => [
      %{
        "uri" => @uri,
        "name" => "本文と音声",
        "description" => "ordered Unicode descriptor",
        "mimeType" => "text/plain; charset=utf-8",
        "annotations" => %{"audience" => ["user"], "priority" => 0.5},
        "_meta" => %{"fixture/order" => [3, 1]}
      },
      %{"uri" => "fixture://binary/second", "name" => "second", "size" => 4}
    ],
    "nextCursor" => @cursor,
    "_meta" => %{"fixture/page" => "最初"}
  }
  @second_page %{
    "resources" => [%{"uri" => "fixture://last", "name" => "最後"}],
    "_meta" => %{"fixture/page" => "最後"}
  }
  @templates %{
    "resourceTemplates" => [
      %{
        "uriTemplate" => "fixture://資料/{id}{?language}",
        "name" => "資料 template",
        "description" => "Read a selected document",
        "mimeType" => "text/plain",
        "_meta" => %{"fixture/template" => %{"languages" => ["日本語", "English"]}}
      }
    ],
    "nextCursor" => "template/next",
    "_meta" => %{"fixture/cursor" => "retained"}
  }
  @read_result %{
    "contents" => [
      %{
        "uri" => @uri,
        "mimeType" => "text/plain; charset=utf-8",
        "text" => "原文 αβ\nsecond line 🎼",
        "_meta" => %{"fixture/part" => 1}
      },
      %{
        "uri" => @uri,
        "mimeType" => "application/octet-stream",
        "blob" => Base.encode64(<<0, 255, 17, 128>>),
        "_meta" => %{"fixture/part" => 2}
      }
    ],
    "_meta" => %{"fixture/order" => ["text", "blob"]}
  }

  test "mixed source preserves resource pages, templates and ordered contents beside tools" do
    ctx = start_source(true)
    assert {:ok, snapshot} = MCP.runtime_snapshot(ctx.config.id)
    assert [%{raw_name: "echo"}] = snapshot.tools

    exercise_resources(ctx, snapshot)

    assert {:ok, %{"content" => [%{"type" => "text", "text" => "tool still works"}]}} =
             Server.runtime_call(snapshot, "echo", %{"label" => "tool still works"}, 2_000)

    assert requests(ctx.calls, "tools/list") == [%{}]

    assert requests(ctx.calls, "tools/call") == [
             %{"name" => "echo", "arguments" => %{"label" => "tool still works"}}
           ]

    assert Process.alive?(ctx.server)
    assert {:ok, ^snapshot} = Server.runtime_snapshot(ctx.server)
  end

  test "resource-only capability publishes an empty tool snapshot without tools discovery" do
    ctx = start_source(false)
    assert :ok = Server.await_ready(ctx.server)
    assert {:ok, snapshot} = MCP.runtime_snapshot(ctx.config.id)
    assert snapshot.source_id == ctx.config.id
    assert snapshot.server_pid == ctx.server
    assert snapshot.generation > 0
    assert snapshot.tools == []

    exercise_resources(ctx, snapshot)

    assert requests(ctx.calls, "tools/list") == []
    assert requests(ctx.calls, "tools/call") == []
    assert Process.alive?(ctx.server)
    assert {:ok, ^snapshot} = Server.runtime_snapshot(ctx.server)
  end

  defp exercise_resources(ctx, snapshot) do
    owner = self()
    Code.ensure_loaded!(Client)

    functions = [
      start_list_resources: 2,
      start_list_resource_templates: 2,
      start_read_resource: 3
    ]

    {tracer, monitor} = spawn_monitor(fn -> trace_calls(owner) end)

    for {name, arity} <- functions,
        do: assert(:erlang.trace_pattern({Client, name, arity}, true, [:local]) == 1)

    assert :erlang.trace(self(), true, [:call, {:tracer, tracer}]) == 1

    try do
      assert {:ok, @first_page} =
               MCP.runtime_list_resources(snapshot, %{"_meta" => @request_meta}, 2_000)

      assert_receive {:resource_public_start, ^owner, :start_list_resources, client}, 2_000
      assert Process.alive?(client)

      assert {:ok, @templates} =
               MCP.runtime_list_resource_templates(
                 snapshot,
                 %{"cursor" => @template_cursor},
                 2_000
               )

      assert_receive {:resource_public_start, ^owner, :start_list_resource_templates, ^client},
                     2_000

      assert {:ok, @read_result} =
               MCP.runtime_read_resource(snapshot, %{"uri" => @uri}, 2_000)

      assert_receive {:resource_public_start, ^owner, :start_read_resource, ^client}, 2_000
      assert Process.alive?(ctx.server)
      assert Process.alive?(client)

      assert {:ok, @second_page} =
               Server.runtime_list_resources(snapshot, %{"cursor" => @cursor}, 2_000)

      assert_receive {:resource_public_start, ^owner, :start_list_resources, ^client}, 2_000
      assert Process.alive?(client)

      assert requests(ctx.calls, "resources/list") == [
               %{"_meta" => @request_meta},
               %{"cursor" => @cursor}
             ]

      assert requests(ctx.calls, "resources/templates/list") == [
               %{"cursor" => @template_cursor}
             ]

      assert requests(ctx.calls, "resources/read") == [%{"uri" => @uri}]
    after
      :erlang.trace(self(), false, [:call])

      for {name, arity} <- functions,
          do: :erlang.trace_pattern({Client, name, arity}, false, [:local])

      send(tracer, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^tracer, :normal}, 2_000
    end
  end

  defp start_source(tools?) do
    calls = start_supervised!({Agent, fn -> [] end})
    fixture = Gaoxy.Test.open()

    Gaoxy.Test.stub(fixture, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      Agent.update(calls, &(&1 ++ [request]))

      result =
        case request["method"] do
          "initialize" ->
            capabilities = %{"resources" => %{"listChanged" => false, "subscribe" => false}}
            capabilities = if tools?, do: Map.put(capabilities, "tools", %{}), else: capabilities

            %{
              "protocolVersion" => request["params"]["protocolVersion"],
              "capabilities" => capabilities,
              "serverInfo" => %{"name" => "resource-fixture", "version" => "1"}
            }

          "tools/list" ->
            %{
              "tools" => [
                %{
                  "name" => "echo",
                  "description" => "Echo an ordinary label",
                  "inputSchema" => %{"type" => "object"}
                }
              ]
            }

          "tools/call" ->
            %{
              "content" => [
                %{"type" => "text", "text" => request["params"]["arguments"]["label"]}
              ]
            }

          "resources/list" ->
            if request["params"]["cursor"] == @cursor, do: @second_page, else: @first_page

          "resources/templates/list" ->
            @templates

          "resources/read" ->
            @read_result

          _notification ->
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

    {:ok, config} =
      MCPConfigs.create(%{
        name: "resource-#{System.unique_integer([:positive, :monotonic])}",
        transport: "streamable_http",
        url: String.trim_trailing(Gaoxy.Test.url(fixture), "/")
      })

    on_exit(fn -> MCPConfigs.delete(config) end)
    server = start_supervised!(Supervisor.child_spec({Server, config}, restart: :temporary))
    assert :ok = Server.await_ready(server)
    %{server: server, config: config, calls: calls}
  end

  defp requests(calls, method) do
    Agent.get(calls, fn requests ->
      for %{"method" => ^method} = request <- requests, do: Map.get(request, "params", %{})
    end)
  end

  defp trace_calls(owner) do
    receive do
      {:trace, caller, :call, {Client, name, [client | _arguments]}} ->
        send(owner, {:resource_public_start, caller, name, client})
        trace_calls(owner)

      :stop ->
        :ok
    end
  end
end
