defmodule Synapsis.MCP.ResourceStartFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.McpProtocol.Client
  alias Backplane.McpProtocol.Client.ResourceRequest
  alias Backplane.McpProtocol.MCP.Response
  alias Synapsis.MCP
  alias Synapsis.MCP.Server
  alias Synapsis.MCPConfigs

  @uri "fixture://資料/原文?part=音声+本文"
  @cursor "次の頁/opaque+cursor=="
  @meta %{"synapsis/resource" => %{"label" => "雪\r\n🎥", "order" => [2, 1]}}

  for {kind, method, starter} <- [
        {:list, "resources/list", :start_list_resources},
        {:templates, "resources/templates/list", :start_list_resource_templates},
        {:read, "resources/read", :start_read_resource}
      ] do
    @tag resource_kind: kind, resource_method: method, public_starter: starter
    test "#{kind} starts an exact caller-owned tracked resource request", context do
      source = start_source()
      assert {:ok, snapshot} = MCP.runtime_snapshot(source.config.id)
      assert snapshot.tools == []
      owner = self()
      deadline = System.monotonic_time(:millisecond) + 5_000

      reserved = [
        timeout: 6_000,
        registration_timeout: 700,
        retirement_deadline: deadline,
        track_retirement: true
      ]

      params =
        if context.resource_kind == :read,
          do: %{"uri" => @uri, "_meta" => @meta},
          else: %{"cursor" => @cursor, "_meta" => @meta}

      starter = context.public_starter
      arity = if context.resource_kind == :read, do: 3, else: 2
      Code.ensure_loaded!(Client)
      {tracer, monitor} = spawn_monitor(fn -> trace_starts(owner) end)
      assert :erlang.trace_pattern({Client, starter, arity}, true, [:local]) == 1
      assert :erlang.trace(self(), true, [:call, {:tracer, tracer}]) == 1

      try do
        assert {:ok, %ResourceRequest{owner: ^owner, retirement_deadline: ^deadline} = handle} =
                 MCP.runtime_start_resource_request(
                   snapshot,
                   context.resource_kind,
                   params,
                   reserved
                 )

        assert {:ok, identity} = Client.resource_request_identity(handle)
        assert handle.identity == identity
        assert_receive {:resource_start, ^owner, ^starter, client, options}, 2_000
        assert handle.client == client
        assert options[:track_retirement] == true
        assert options[:retirement_deadline] == deadline
        assert options[:timeout] > 0 and options[:timeout] <= 5_000
        assert options[:registration_timeout] > 0 and options[:registration_timeout] <= 700
        assert options[:meta] == @meta

        expected = result(context.resource_method)
        assert {:ok, %Response{result: ^expected}} = Client.await_resource_request(handle, 2_000)

        assert {:ok, %{local_cleanup: :confirmed}} =
                 Client.retire_resource_request(handle, timeout: 2_000, deadline: deadline)

        assert requests(source.calls, context.resource_method) == [params]
        assert requests(source.calls, "tools/list") == []
        assert Process.alive?(source.server)
        assert Process.alive?(client)
        assert {:ok, ^snapshot} = MCP.runtime_snapshot(source.config.id)
      after
        :erlang.trace(self(), false, [:call])
        :erlang.trace_pattern({Client, starter, arity}, false, [:local])
        send(tracer, :stop)
        assert_receive {:DOWN, ^monitor, :process, ^tracer, :normal}, 2_000
      end
    end
  end

  defp result("resources/list") do
    %{
      "resources" => [%{"uri" => @uri, "name" => "原文", "mimeType" => "text/plain"}],
      "nextCursor" => @cursor,
      "_meta" => @meta,
      "fixture/extension" => [nil, false, "保持"]
    }
  end

  defp result("resources/templates/list") do
    %{
      "resourceTemplates" => [
        %{"uriTemplate" => "fixture://資料/{id}{?language}", "name" => "資料"}
      ],
      "nextCursor" => @cursor,
      "_meta" => @meta,
      "fixture/extension" => [nil, false, "保持"]
    }
  end

  defp result("resources/read") do
    %{
      "contents" => [
        %{"uri" => @uri, "text" => "原文 αβ\r\n🎥", "mimeType" => "text/plain"},
        %{
          "uri" => @uri,
          "blob" => Base.encode64(<<0, 255, 17, 128>>),
          "mimeType" => "application/octet-stream"
        }
      ],
      "_meta" => @meta,
      "fixture/extension" => [nil, false, "保持"]
    }
  end

  defp start_source do
    calls = start_supervised!({Agent, fn -> [] end})
    fixture = Gaoxy.Test.open()

    Gaoxy.Test.stub(fixture, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      Agent.update(calls, &(&1 ++ [request]))

      response =
        case request["method"] do
          "initialize" ->
            %{
              "protocolVersion" => request["params"]["protocolVersion"],
              "capabilities" => %{"resources" => %{"subscribe" => false}},
              "serverInfo" => %{"name" => "resource-start-fixture", "version" => "1"}
            }

          method
          when method in ["resources/list", "resources/templates/list", "resources/read"] ->
            result(method)

          _notification ->
            %{}
        end

      if Map.has_key?(request, "id") do
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => response})
        )
      else
        Plug.Conn.resp(conn, 202, "")
      end
    end)

    for method <- ["GET", "DELETE"],
        do: Gaoxy.Test.stub(fixture, method, "/mcp", &Plug.Conn.resp(&1, 200, ""))

    {:ok, config} =
      MCPConfigs.create(%{
        name: "resource-start-#{System.unique_integer([:positive, :monotonic])}",
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

  defp trace_starts(owner) do
    receive do
      {:trace, caller, :call, {Client, name, [client | arguments]}} ->
        send(owner, {:resource_start, caller, name, client, List.last(arguments)})
        trace_starts(owner)

      :stop ->
        :ok
    end
  end
end
