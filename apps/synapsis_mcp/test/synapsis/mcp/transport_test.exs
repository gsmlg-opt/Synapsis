defmodule Synapsis.MCP.TransportTest do
  use ExUnit.Case, async: true

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
