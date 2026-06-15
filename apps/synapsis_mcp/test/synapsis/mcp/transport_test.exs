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

  test "builds a streamable_http tuple with base_url and headers" do
    cfg = %MCPConfig{transport: "streamable_http", url: "https://h/mcp", headers: %{"A" => "b"}}

    assert {:streamable_http, opts} = Transport.build(cfg)
    assert opts[:base_url] == "https://h/mcp"
    assert opts[:headers] == %{"A" => "b"}
  end

  test "builds an sse tuple with nested server base_url and top-level headers" do
    cfg = %MCPConfig{transport: "sse", url: "https://h", headers: %{"A" => "b"}}

    assert {:sse, opts} = Transport.build(cfg)
    assert opts[:server][:base_url] == "https://h"
    assert opts[:headers] == %{"A" => "b"}
  end
end
