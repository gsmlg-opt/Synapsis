defmodule Synapsis.MCP.TransportTest do
  use ExUnit.Case, async: false

  alias Synapsis.Backplane.Connection
  alias Synapsis.MCP.Transport
  alias Synapsis.MCPConfig

  test "builds a stdio tuple with command, args, env" do
    cfg = %MCPConfig{transport: "stdio", command: "uvx", args: ["x"], env: %{"K" => "v"}}

    assert {:stdio, opts} = Transport.build(cfg)
    assert opts[:command] == "uvx"
    assert opts[:args] == ["x"]
    assert opts[:env] == %{"K" => "v"}
  end

  test "builds a streamable_http tuple splitting url into base_url + mcp_path" do
    cfg = %MCPConfig{transport: "streamable_http", url: "https://h/mcp", headers: %{"A" => "b"}}

    assert {:streamable_http, opts} = Transport.build(cfg)
    assert opts[:base_url] == "https://h"
    assert opts[:mcp_path] == "/mcp"
    assert opts[:headers] == %{"A" => "b"}
  end

  test "streamable_http preserves a custom endpoint path (no double /mcp)" do
    cfg = %MCPConfig{transport: "streamable_http", url: "http://10.0.0.1:4220/api/mcp"}

    assert {:streamable_http, opts} = Transport.build(cfg)
    assert opts[:base_url] == "http://10.0.0.1:4220"
    assert opts[:mcp_path] == "/api/mcp"
  end

  test "streamable_http defaults mcp_path to /mcp when url has no path" do
    cfg = %MCPConfig{transport: "streamable_http", url: "http://localhost:8000"}

    assert {:streamable_http, opts} = Transport.build(cfg)
    assert opts[:base_url] == "http://localhost:8000"
    assert opts[:mcp_path] == "/mcp"
  end

  test "injects a source credential only while its Backplane connection is enabled" do
    assert {:ok, connection} =
             Connection.create(%{
               name: "transport-source-#{System.unique_integer([:positive])}",
               endpoint: "https://backplane.example.test",
               credential: "  source-secret  ",
               enabled: false
             })

    on_exit(fn -> Connection.delete(connection) end)

    config = %MCPConfig{
      transport: "streamable_http",
      url: "https://mcp.example.test/mcp",
      headers: %{"x-local" => "present"},
      config: %{"backplane_source_id" => connection.id}
    }

    assert {:streamable_http, disabled_opts} = Transport.build(config)
    assert disabled_opts[:headers] == %{"x-local" => "present"}

    assert {:ok, _enabled} = Connection.update(connection, %{enabled: true})
    assert {:streamable_http, enabled_opts} = Transport.build(config)

    assert enabled_opts[:headers] == %{
             "x-local" => "present",
             "authorization" => "Bearer   source-secret  "
           }

    assert {:ok, keyless} =
             Connection.create(%{
               name: "keyless-transport-source-#{System.unique_integer([:positive])}",
               endpoint: "https://backplane.example.test",
               credential: "   ",
               enabled: true
             })

    on_exit(fn -> Connection.delete(keyless) end)

    keyless_config = %{
      config
      | config: %{"backplane_source_id" => keyless.id}
    }

    assert {:streamable_http, keyless_opts} = Transport.build(keyless_config)
    assert keyless_opts[:headers] == %{"x-local" => "present"}

    missing_config = %{
      config
      | config: %{"backplane_source_id" => Ecto.UUID.generate()}
    }

    assert {:streamable_http, missing_opts} = Transport.build(missing_config)
    assert missing_opts[:headers] == %{"x-local" => "present"}
  end

  test "builds an sse tuple with nested server base_url and top-level headers" do
    cfg = %MCPConfig{transport: "sse", url: "https://h", headers: %{"A" => "b"}}

    assert {:sse, opts} = Transport.build(cfg)
    assert opts[:server][:base_url] == "https://h"
    assert opts[:headers] == %{"A" => "b"}
  end

  test "selects the protocol version supported by the configured transport" do
    assert Transport.protocol_version(%MCPConfig{transport: "stdio"}) == "2025-06-18"
    assert Transport.protocol_version(%MCPConfig{transport: "streamable_http"}) == "2025-06-18"
    assert Transport.protocol_version(%MCPConfig{transport: "sse"}) == "2024-11-05"
  end
end
