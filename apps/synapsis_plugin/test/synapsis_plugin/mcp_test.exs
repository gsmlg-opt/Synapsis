defmodule SynapsisPlugin.MCPTest do
  use ExUnit.Case, async: true

  alias SynapsisPlugin.MCP.Protocol

  describe "MCP Protocol" do
    test "encodes a JSON-RPC request" do
      encoded = Protocol.encode_request(1, "tools/list")
      assert encoded =~ "\"jsonrpc\":\"2.0\""
      assert encoded =~ "\"id\":1"
      assert encoded =~ "\"method\":\"tools/list\""
      assert String.ends_with?(encoded, "\n")
    end

    test "encodes a request with explicit params" do
      params = %{"name" => "read_file", "arguments" => %{"path" => "/tmp/test.txt"}}
      encoded = Protocol.encode_request(42, "tools/call", params)
      decoded = Jason.decode!(String.trim_trailing(encoded, "\n"))
      assert decoded["id"] == 42
      assert decoded["method"] == "tools/call"
      assert decoded["params"]["name"] == "read_file"
      assert decoded["params"]["arguments"]["path"] == "/tmp/test.txt"
    end

    test "encodes a notification" do
      encoded = Protocol.encode_notification("notifications/initialized")
      assert encoded =~ "\"method\":\"notifications/initialized\""
      refute encoded =~ "\"id\""
    end

    test "encodes a notification with explicit params" do
      encoded = Protocol.encode_notification("notifications/progress", %{"sessionId" => "abc123"})
      decoded = Jason.decode!(String.trim_trailing(encoded, "\n"))
      assert decoded["method"] == "notifications/progress"
      assert decoded["params"]["sessionId"] == "abc123"
      refute Map.has_key?(decoded, "id")
    end

    test "decodes a complete message" do
      json = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{"tools" => []}})
      {messages, rest} = Protocol.decode_message("#{json}\n")
      assert length(messages) == 1
      assert hd(messages)["id"] == 1
      assert rest == ""
    end

    test "decodes multiple messages" do
      msg1 = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}})
      msg2 = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notify", "params" => %{}})
      {messages, _rest} = Protocol.decode_message("#{msg1}\n#{msg2}\n")
      assert length(messages) == 2
    end

    test "handles partial messages" do
      {messages, rest} = Protocol.decode_message("{incomplete")
      assert messages == []
      assert rest == "{incomplete"
    end
  end

  describe "MCP plugin module" do
    test "tools/1 formats tool names with server prefix" do
      state = %SynapsisPlugin.MCP{
        server_name: "my_server",
        tools: [
          %{"name" => "read_file", "description" => "Read a file", "inputSchema" => %{}}
        ],
        port: nil,
        request_id: 1,
        pending: %{},
        buffer: "",
        env: %{},
        initialized: true,
        command: "test",
        args: []
      }

      tools = SynapsisPlugin.MCP.tools(state)
      assert length(tools) == 1
      assert hd(tools).name == "mcp:my_server:read_file"
    end
  end
end
