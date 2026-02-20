defmodule SynapsisPlugin.MCP.ProtocolTest do
  use ExUnit.Case, async: true

  alias SynapsisPlugin.MCP.Protocol

  describe "encode_request/3" do
    test "encodes a tools/list request with newline delimiter" do
      encoded = Protocol.encode_request(1, "tools/list")
      assert String.ends_with?(encoded, "\n")

      json = String.trim_trailing(encoded, "\n")
      {:ok, decoded} = Jason.decode(json)
      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 1
      assert decoded["method"] == "tools/list"
      assert decoded["params"] == %{}
    end

    test "encodes a tools/call request with arguments" do
      params = %{"name" => "read_file", "arguments" => %{"path" => "/tmp/test.txt"}}
      encoded = Protocol.encode_request(2, "tools/call", params)

      json = String.trim_trailing(encoded, "\n")
      {:ok, decoded} = Jason.decode(json)
      assert decoded["id"] == 2
      assert decoded["method"] == "tools/call"
      assert decoded["params"]["name"] == "read_file"
      assert decoded["params"]["arguments"]["path"] == "/tmp/test.txt"
    end

    test "encodes an initialize request" do
      params = %{
        "protocolVersion" => "2024-11-05",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "synapsis", "version" => "0.1.0"}
      }

      encoded = Protocol.encode_request(1, "initialize", params)
      json = String.trim_trailing(encoded, "\n")
      {:ok, decoded} = Jason.decode(json)
      assert decoded["method"] == "initialize"
      assert decoded["params"]["protocolVersion"] == "2024-11-05"
      assert decoded["params"]["clientInfo"]["name"] == "synapsis"
    end

    test "defaults params to empty map" do
      encoded = Protocol.encode_request(5, "some/method")
      json = String.trim_trailing(encoded, "\n")
      {:ok, decoded} = Jason.decode(json)
      assert decoded["params"] == %{}
    end

    test "each request has exactly one newline at the end" do
      encoded = Protocol.encode_request(1, "test")
      assert String.ends_with?(encoded, "\n")
      refute String.ends_with?(encoded, "\n\n")
    end
  end

  describe "encode_notification/2" do
    test "encodes a notification without id" do
      encoded = Protocol.encode_notification("notifications/initialized")
      assert String.ends_with?(encoded, "\n")

      json = String.trim_trailing(encoded, "\n")
      {:ok, decoded} = Jason.decode(json)
      assert decoded["jsonrpc"] == "2.0"
      assert decoded["method"] == "notifications/initialized"
      refute Map.has_key?(decoded, "id")
    end

    test "encodes a notification with params" do
      encoded = Protocol.encode_notification("notifications/progress", %{"token" => "abc", "value" => 50})
      json = String.trim_trailing(encoded, "\n")
      {:ok, decoded} = Jason.decode(json)
      assert decoded["params"]["token"] == "abc"
      assert decoded["params"]["value"] == 50
    end

    test "defaults params to empty map" do
      encoded = Protocol.encode_notification("notifications/test")
      json = String.trim_trailing(encoded, "\n")
      {:ok, decoded} = Jason.decode(json)
      assert decoded["params"] == %{}
    end
  end

  describe "decode_message/1" do
    test "decodes a single complete message" do
      json = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{"tools" => []}})
      {messages, rest} = Protocol.decode_message("#{json}\n")
      assert length(messages) == 1
      assert hd(messages)["id"] == 1
      assert hd(messages)["result"]["tools"] == []
      assert rest == ""
    end

    test "decodes a tools/list response" do
      tools = [
        %{"name" => "read_file", "description" => "Read a file", "inputSchema" => %{"type" => "object"}},
        %{"name" => "write_file", "description" => "Write a file", "inputSchema" => %{"type" => "object"}}
      ]

      json = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{"tools" => tools}})
      {messages, ""} = Protocol.decode_message("#{json}\n")
      assert length(messages) == 1
      result_tools = hd(messages)["result"]["tools"]
      assert length(result_tools) == 2
      assert Enum.map(result_tools, & &1["name"]) == ["read_file", "write_file"]
    end

    test "decodes a tools/call response" do
      result = %{
        "content" => [%{"type" => "text", "text" => "file contents here"}]
      }

      json = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 3, "result" => result})
      {messages, ""} = Protocol.decode_message("#{json}\n")
      assert length(messages) == 1
      content = hd(messages)["result"]["content"]
      assert hd(content)["text"] == "file contents here"
    end

    test "decodes an error response" do
      error = %{"code" => -32_601, "message" => "Method not found"}
      json = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 2, "error" => error})
      {messages, ""} = Protocol.decode_message("#{json}\n")
      assert length(messages) == 1
      assert hd(messages)["error"]["code"] == -32_601
      assert hd(messages)["error"]["message"] == "Method not found"
    end

    test "decodes multiple messages in one buffer" do
      msg1 = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}})
      msg2 = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notify", "params" => %{}})
      {messages, _rest} = Protocol.decode_message("#{msg1}\n#{msg2}\n")
      assert length(messages) == 2
      assert Enum.at(messages, 0)["id"] == 1
      assert Enum.at(messages, 1)["method"] == "notify"
    end

    test "handles partial (incomplete) messages" do
      {messages, rest} = Protocol.decode_message("{incomplete")
      assert messages == []
      assert rest == "{incomplete"
    end

    test "handles empty input" do
      {messages, rest} = Protocol.decode_message("")
      assert messages == []
      assert rest == ""
    end

    test "handles mixed complete and partial messages" do
      complete = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}})
      {messages, rest} = Protocol.decode_message("#{complete}\n{partial")
      assert length(messages) == 1
      assert rest == "{partial"
    end

    test "decodes an initialize response" do
      result = %{
        "protocolVersion" => "2024-11-05",
        "capabilities" => %{"tools" => %{"listChanged" => true}},
        "serverInfo" => %{"name" => "test-server", "version" => "1.0.0"}
      }

      json = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => result})
      {messages, ""} = Protocol.decode_message("#{json}\n")
      assert length(messages) == 1
      assert hd(messages)["result"]["protocolVersion"] == "2024-11-05"
      assert hd(messages)["result"]["serverInfo"]["name"] == "test-server"
    end
  end
end
