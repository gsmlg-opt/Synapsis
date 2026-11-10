defmodule Synapsis.MCP.InspectionMetadataFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.MCP
  alias Synapsis.MCP.{Response, Server}
  alias Synapsis.MCPConfigs

  @modern "2026-07-28"
  @instructions String.duplicate("完整说明 雪 é 🎥\nPreserve every advertised instruction.\n", 24)
  @description "Find an exact note.\n原样 é 🎥"
  @input_schema %{
    "type" => "object",
    "properties" => %{
      "operation" => %{"type" => "string", "enum" => ["lookup"]},
      "query" => %{
        "type" => "object",
        "properties" => %{"label" => %{"type" => "string", "description" => "雪\né"}},
        "required" => ["label"],
        "additionalProperties" => false
      }
    },
    "required" => ["operation", "query"],
    "additionalProperties" => false
  }
  @output_schema %{
    "type" => "object",
    "properties" => %{
      "ok" => %{"type" => "boolean"},
      "entries" => %{"type" => "array", "items" => %{"type" => "string"}}
    },
    "required" => ["ok", "entries"],
    "additionalProperties" => false
  }

  setup context do
    fixture = Gaoxy.Test.open()
    owner = self()
    mode = Map.get(context, :metadata_mode, :modern)

    Gaoxy.Test.stub(fixture, "GET", "/mcp", &Plug.Conn.resp(&1, 405, ""))
    Gaoxy.Test.stub(fixture, "DELETE", "/mcp", &Plug.Conn.resp(&1, 204, ""))

    Gaoxy.Test.stub(fixture, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      send(owner, {:inspection_metadata_http, request["method"], request["params"]})

      if Map.has_key?(request, "id") do
        result =
          case request["method"] do
            "server/discover" -> discovery(mode)
            "initialize" -> legacy_initialize(request)
            "tools/list" -> %{"resultType" => "complete", "tools" => [tool()]}
          end

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

    options = if mode == :legacy, do: %{}, else: %{"protocol_version" => @modern}

    {:ok, config} =
      MCPConfigs.create(%{
        name: "inspection-metadata-#{System.unique_integer([:positive])}",
        transport: "streamable_http",
        url: Gaoxy.Test.url(fixture, "/mcp"),
        config: options
      })

    on_exit(fn ->
      MCP.stop(config.name)
      MCPConfigs.delete(config)
      Gaoxy.Test.close(fixture)
    end)

    assert {:ok, pid} = MCP.start(config)
    assert :ok = Server.await_ready(pid)
    %{config: config, pid: pid, fixture: fixture}
  end

  test "modern discovery retains complete instructions and input/output schemas in one source snapshot",
       ctx do
    assert_receive {:inspection_metadata_http, "server/discover", params}, 2_000
    assert params["_meta"]["io.modelcontextprotocol/protocolVersion"] == @modern
    assert_receive {:inspection_metadata_http, "tools/list", _}, 2_000
    assert String.length(@instructions) > 512

    assert {:ok, snapshot} = Server.runtime_snapshot(ctx.pid)
    assert Enum.sort(Map.keys(snapshot)) == ~w(generation server_pid source_id tools)a
    assert snapshot.source_id == ctx.config.id
    assert snapshot.server_pid == ctx.pid
    assert snapshot.generation == 1

    assert snapshot.tools == [
             %{
               raw_name: "notes.lookup",
               description: @description,
               parameters: @input_schema,
               output_schema: @output_schema,
               annotations: nil,
               permission_level: :write,
               source_metadata: %{
                 server_name: ctx.config.name,
                 instructions_status: "available",
                 instructions: @instructions
               }
             }
           ]

    assert {:ok, ^snapshot} = MCP.runtime_snapshot(ctx.config.id)
    assert {:ok, ^snapshot} = Server.runtime_snapshot(ctx.pid)
    Gaoxy.Test.verify!(ctx.fixture)
  end

  @tag metadata_mode: :modern_absent
  test "modern discovery without instructions records its supported source receipt", ctx do
    assert {:ok, %{tools: [tool]}} = Server.runtime_snapshot(ctx.pid)

    assert tool.source_metadata == %{
             server_name: ctx.config.name,
             instructions_status: "not_advertised"
           }

    assert tool.parameters == @input_schema
    assert tool.output_schema == @output_schema
    assert_receive {:inspection_metadata_http, "server/discover", _}, 2_000
  end

  @tag metadata_mode: :modern_empty
  test "an explicitly empty modern instruction string is retained as available", ctx do
    assert {:ok, %{tools: [tool]}} = Server.runtime_snapshot(ctx.pid)

    assert tool.source_metadata == %{
             server_name: ctx.config.name,
             instructions_status: "available",
             instructions: ""
           }

    assert_receive {:inspection_metadata_http, "server/discover", _}, 2_000
  end

  @tag metadata_mode: :legacy
  test "ordinary legacy discovery records that top-level instructions were not retained", ctx do
    assert_receive {:inspection_metadata_http, "initialize", params}, 2_000
    assert params["protocolVersion"] == "2025-06-18"
    assert {:ok, %{tools: [tool]}} = Server.runtime_snapshot(ctx.pid)

    assert tool.source_metadata == %{
             server_name: ctx.config.name,
             instructions_status: "not_retained_legacy"
           }

    assert tool.parameters == @input_schema
    assert tool.output_schema == @output_schema
  end

  @tag metadata_mode: :legacy
  test "normalization preserves optional output metadata and the existing absent-output map",
       _ctx do
    assert [normalized] = Response.tools(%{"tools" => [tool()]}, "public-notes")
    assert normalized.parameters == @input_schema
    assert normalized.output_schema == @output_schema
    assert normalized.description == @description

    assert Response.tools(
             %{"tools" => [%{"name" => "plain", "inputSchema" => %{"type" => "object"}}]},
             "public-notes"
           ) == [
             %{
               name: "mcp:public-notes:plain",
               description: "",
               parameters: %{"type" => "object"},
               annotations: nil,
               trust_annotations: false,
               permission_level: :write
             }
           ]
  end

  defp discovery(mode) do
    result = %{
      "resultType" => "complete",
      "supportedVersions" => [@modern],
      "capabilities" => %{"tools" => %{}},
      "ttlMs" => 0,
      "cacheScope" => "private"
    }

    case mode do
      :modern -> Map.put(result, "instructions", @instructions)
      :modern_empty -> Map.put(result, "instructions", "")
      :modern_absent -> result
    end
  end

  defp legacy_initialize(request) do
    %{
      "protocolVersion" => request["params"]["protocolVersion"],
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{"name" => "remote-notes", "version" => "1"},
      "instructions" => @instructions
    }
  end

  defp tool do
    %{
      "name" => "notes.lookup",
      "description" => @description,
      "inputSchema" => @input_schema,
      "outputSchema" => @output_schema
    }
  end
end
