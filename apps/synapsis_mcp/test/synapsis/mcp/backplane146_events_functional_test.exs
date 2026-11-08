defmodule Synapsis.MCP.Backplane146EventsFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.McpProtocol.Client

  @version "2026-07-28"
  @first_cursor "opaque/first+雪"
  @second_cursor "opaque/next?label=汉字+é"
  @request_meta %{
    "synapsis/events" => %{"label" => "汉字\r\n🎥", "nested" => [1, true, %{"雪" => "é"}]}
  }

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    owner = self()

    Gaoxy.Test.stub(fixture, "GET", "/mcp", &Plug.Conn.resp(&1, 405, ""))
    Gaoxy.Test.stub(fixture, "DELETE", "/mcp", &Plug.Conn.resp(&1, 204, ""))

    Gaoxy.Test.stub(fixture, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      wire = Jason.decode!(body)
      headers = Map.new(conn.req_headers)
      send(owner, {:events_http, wire["method"], wire["params"], headers, wire["id"]})

      if Map.has_key?(wire, "id") do
        result = result(wire)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => wire["id"], "result" => result})
        )
      else
        Plug.Conn.resp(conn, 202, "")
      end
    end)

    name = String.to_atom("SynapsisEvents146#{System.unique_integer([:positive])}")

    supervisor =
      start_supervised!(
        {Client,
         name: name,
         transport: {:streamable_http, url: Gaoxy.Test.url(fixture, "/mcp")},
         one_shot: true,
         activation_id: "events-functional-#{name}",
         client_info: %{"name" => "synapsis-events-functional", "version" => "1"},
         capabilities: %{},
         protocol_version: @version,
         timeout: 3_000}
      )

    assert :ok = Client.await_ready(name, timeout: 3_000)
    assert_receive {:events_http, "server/discover", discovery, discovery_headers, _id}, 3_000
    assert discovery["_meta"]["io.modelcontextprotocol/protocolVersion"] == @version
    assert discovery_headers["mcp-method"] == "server/discover"

    %{fixture: fixture, client: name, client_pid: Process.whereis(name), supervisor: supervisor}
  end

  test "original caller awaits an entire raw event page with boolean and object payload schemas",
       ctx do
    assert {:ok, handle} =
             Client.start_list_events(ctx.client, cursor: @first_cursor, meta: @request_meta)

    assert is_struct(handle)

    assert Atom.to_string(Map.fetch!(handle, :__struct__)) ==
             "Elixir.Backplane.McpProtocol.Client.EventRequest"

    assert handle.owner == self()
    assert handle.client == ctx.client_pid
    assert {:ok, response} = Client.await_event_request(handle, 2_000)
    assert response.result == first_page()

    assert response.result["events"] |> Enum.map(& &1["name"]) == [
             "comment.created",
             "comment.updated"
           ]

    assert response.result["events"] |> Enum.map(& &1["payloadSchema"]) == [
             true,
             %{
               "type" => "object",
               "properties" => %{"内容" => %{"type" => "string"}},
               "additionalProperties" => false
             }
           ]

    assert_receive {:events_http, "events/list", params, headers, id}, 1_000
    assert response.id == id
    assert_event_request(params, headers, @first_cursor)
    assert Process.alive?(ctx.client_pid)
    assert Process.alive?(ctx.supervisor)
    assert Process.whereis(ctx.client) == ctx.client_pid
    Gaoxy.Test.verify!(ctx.fixture)
  end

  test "two explicit event cursor pages retain raw order and leave ordinary resources and tools usable",
       ctx do
    assert {:ok, first} =
             Client.start_list_events(ctx.client, cursor: @first_cursor, meta: @request_meta)

    assert first.owner == self()
    assert {:ok, first_response} = Client.await_event_request(first, 2_000)
    assert first_response.result == first_page()
    assert_receive {:events_http, "events/list", first_params, first_headers, first_id}, 1_000
    assert first_response.id == first_id
    assert_event_request(first_params, first_headers, @first_cursor)

    next_cursor = first_response.result["nextCursor"]
    assert next_cursor == @second_cursor

    assert {:ok, second} =
             Client.start_list_events(ctx.client, cursor: next_cursor, meta: @request_meta)

    assert second.owner == self()
    assert second.client == first.client
    assert {:ok, second_response} = Client.await_event_request(second, 2_000)
    assert second_response.result == second_page()
    assert_receive {:events_http, "events/list", second_params, second_headers, second_id}, 1_000
    assert second_response.id == second_id
    assert_event_request(second_params, second_headers, @second_cursor)

    events = first_response.result["events"] ++ second_response.result["events"]

    assert Enum.map(events, & &1["name"]) == [
             "comment.created",
             "comment.updated",
             "媒体.完成",
             "job.finished"
           ]

    assert Enum.map(events, & &1["payloadSchema"]) == [
             true,
             %{
               "type" => "object",
               "properties" => %{"内容" => %{"type" => "string"}},
               "additionalProperties" => false
             },
             false,
             %{"type" => "object"}
           ]

    assert {:ok, resource} =
             Client.start_list_resources(ctx.client,
               cursor: "resources/next",
               meta: %{"synapsis/resources" => "雪"}
             )

    assert {:ok, resources} = Client.await_resource_request(resource, 2_000)
    assert resources.result == resource_page()
    assert_receive {:events_http, "resources/list", resource_params, resource_headers, _id}, 1_000
    assert resource_params["cursor"] == "resources/next"
    assert resource_params["_meta"]["synapsis/resources"] == "雪"
    assert resource_params["_meta"]["io.modelcontextprotocol/protocolVersion"] == @version
    assert resource_headers["mcp-method"] == "resources/list"

    assert {:ok, tools} = Client.list_tools(ctx.client, meta: %{"synapsis/tools" => ["汉字", true]})
    assert tools.result == tool_page()
    assert_receive {:events_http, "tools/list", tool_params, tool_headers, _id}, 1_000
    assert tool_params["_meta"]["synapsis/tools"] == ["汉字", true]
    assert tool_params["_meta"]["io.modelcontextprotocol/protocolVersion"] == @version
    assert tool_headers["mcp-method"] == "tools/list"
    assert Process.alive?(ctx.client_pid)
    assert Process.alive?(ctx.supervisor)
    assert Process.whereis(ctx.client) == ctx.client_pid
    Gaoxy.Test.verify!(ctx.fixture)
  end

  defp assert_event_request(params, headers, cursor) do
    assert params["cursor"] == cursor
    assert params["_meta"]["synapsis/events"] == @request_meta["synapsis/events"]
    assert params["_meta"]["io.modelcontextprotocol/protocolVersion"] == @version
    assert headers["mcp-method"] == "events/list"
  end

  defp result(%{"method" => "server/discover"}) do
    %{
      "resultType" => "complete",
      "supportedVersions" => [@version],
      "capabilities" => %{"resources" => %{}, "tools" => %{}, "events" => %{}},
      "ttlMs" => 0,
      "cacheScope" => "private"
    }
  end

  defp result(%{"method" => "events/list", "params" => %{"cursor" => @first_cursor}}),
    do: first_page()

  defp result(%{"method" => "events/list", "params" => %{"cursor" => @second_cursor}}),
    do: second_page()

  defp result(%{"method" => "resources/list"}), do: resource_page()
  defp result(%{"method" => "tools/list"}), do: tool_page()

  defp first_page do
    %{
      "resultType" => "complete",
      "events" => [
        %{
          "name" => "comment.created",
          "description" => "汉字\r\nfirst 🎥",
          "delivery" => ["webhook"],
          "inputSchema" => %{"type" => "object"},
          "payloadSchema" => true,
          "synapsis/descriptor" => %{"label" => "雪"}
        },
        %{
          "name" => "comment.updated",
          "description" => "é — 更新",
          "delivery" => ["webhook", "other"],
          "inputSchema" => false,
          "payloadSchema" => %{
            "type" => "object",
            "properties" => %{"内容" => %{"type" => "string"}},
            "additionalProperties" => false
          }
        }
      ],
      "nextCursor" => @second_cursor,
      "extra_result" => %{"label" => "原样", "values" => [1, true, nil]}
    }
  end

  defp second_page do
    %{
      "resultType" => "complete",
      "events" => [
        %{
          "name" => "媒体.完成",
          "description" => "完了 🎬",
          "delivery" => ["webhook"],
          "inputSchema" => true,
          "payloadSchema" => false
        },
        %{
          "name" => "job.finished",
          "description" => "Last — 雪",
          "delivery" => ["other", "webhook"],
          "inputSchema" => %{"type" => "object"},
          "payloadSchema" => %{"type" => "object"},
          "extension" => ["汉字", 2]
        }
      ],
      "nextCursor" => "opaque/final+终",
      "extra_result" => ["第二页", %{"kept" => true}]
    }
  end

  defp resource_page do
    %{
      "resultType" => "complete",
      "resources" => [
        %{
          "uri" => "fixture://ordinary/雪",
          "name" => "Ordinary resource",
          "mimeType" => "text/plain"
        }
      ],
      "nextCursor" => "resources/final",
      "extra_result" => %{"kept" => "汉字"}
    }
  end

  defp tool_page do
    %{
      "resultType" => "complete",
      "tools" => [
        %{
          "name" => "echo",
          "description" => "Ordinary echo 雪",
          "inputSchema" => %{"type" => "object", "properties" => %{}}
        }
      ]
    }
  end
end
