defmodule SynapsisPlugin.MCP.ProtocolTest do
  use ExUnit.Case, async: true

  alias SynapsisPlugin.MCP.Protocol

  describe "encode_request/3" do
    test "encodes a tools/list request with newline delimiter" do
      {:ok, encoded} = Protocol.encode_request(1, "tools/list")
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
      {:ok, encoded} = Protocol.encode_request(2, "tools/call", params)

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

      {:ok, encoded} = Protocol.encode_request(1, "initialize", params)
      json = String.trim_trailing(encoded, "\n")
      {:ok, decoded} = Jason.decode(json)
      assert decoded["method"] == "initialize"
      assert decoded["params"]["protocolVersion"] == "2024-11-05"
      assert decoded["params"]["clientInfo"]["name"] == "synapsis"
    end

    test "defaults params to empty map" do
      {:ok, encoded} = Protocol.encode_request(5, "some/method")
      json = String.trim_trailing(encoded, "\n")
      {:ok, decoded} = Jason.decode(json)
      assert decoded["params"] == %{}
    end

    test "each request has exactly one newline at the end" do
      {:ok, encoded} = Protocol.encode_request(1, "test")
      assert String.ends_with?(encoded, "\n")
      refute String.ends_with?(encoded, "\n\n")
    end
  end

  describe "encode_notification/2" do
    test "encodes a notification without id" do
      {:ok, encoded} = Protocol.encode_notification("notifications/initialized")
      assert String.ends_with?(encoded, "\n")

      json = String.trim_trailing(encoded, "\n")
      {:ok, decoded} = Jason.decode(json)
      assert decoded["jsonrpc"] == "2.0"
      assert decoded["method"] == "notifications/initialized"
      refute Map.has_key?(decoded, "id")
    end

    test "encodes a notification with params" do
      {:ok, encoded} = Protocol.encode_notification("notifications/progress", %{"token" => "abc", "value" => 50})
      json = String.trim_trailing(encoded, "\n")
      {:ok, decoded} = Jason.decode(json)
      assert decoded["params"]["token"] == "abc"
      assert decoded["params"]["value"] == 50
    end

    test "defaults params to empty map" do
      {:ok, encoded} = Protocol.encode_notification("notifications/test")
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

  describe "encode/decode round-trip" do
    test "request round-trips through encode then decode" do
      {:ok, encoded} = Protocol.encode_request(7, "tools/list", %{"cursor" => "abc"})
      {[decoded], ""} = Protocol.decode_message(encoded)
      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 7
      assert decoded["method"] == "tools/list"
      assert decoded["params"]["cursor"] == "abc"
    end

    test "notification round-trips through encode then decode" do
      {:ok, encoded} = Protocol.encode_notification("notifications/cancelled", %{"requestId" => 3, "reason" => "timeout"})
      {[decoded], ""} = Protocol.decode_message(encoded)
      assert decoded["jsonrpc"] == "2.0"
      assert decoded["method"] == "notifications/cancelled"
      assert decoded["params"]["requestId"] == 3
      assert decoded["params"]["reason"] == "timeout"
      refute Map.has_key?(decoded, "id")
    end

    test "request with empty params round-trips" do
      {:ok, encoded} = Protocol.encode_request(100, "ping")
      {[decoded], ""} = Protocol.decode_message(encoded)
      assert decoded["id"] == 100
      assert decoded["method"] == "ping"
      assert decoded["params"] == %{}
    end

    test "request with nested params round-trips" do
      params = %{
        "name" => "write_file",
        "arguments" => %{
          "path" => "/tmp/deep/nested/file.txt",
          "content" => "line1\nline2\nline3"
        }
      }

      {:ok, encoded} = Protocol.encode_request(42, "tools/call", params)
      {[decoded], ""} = Protocol.decode_message(encoded)
      assert decoded["params"]["arguments"]["path"] == "/tmp/deep/nested/file.txt"
      assert decoded["params"]["arguments"]["content"] == "line1\nline2\nline3"
    end

    test "request with unicode content round-trips" do
      params = %{"text" => "Hello, \u4e16\u754c! \u{1F600}"}
      {:ok, encoded} = Protocol.encode_request(1, "echo", params)
      {[decoded], ""} = Protocol.decode_message(encoded)
      assert decoded["params"]["text"] == "Hello, \u4e16\u754c! \u{1F600}"
    end
  end

  describe "error response encoding" do
    test "decodes standard JSON-RPC error codes" do
      errors = [
        {-32_700, "Parse error"},
        {-32_600, "Invalid Request"},
        {-32_601, "Method not found"},
        {-32_602, "Invalid params"},
        {-32_603, "Internal error"}
      ]

      for {code, message} <- errors do
        json = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "error" => %{"code" => code, "message" => message}})
        {[decoded], ""} = Protocol.decode_message("#{json}\n")
        assert decoded["error"]["code"] == code
        assert decoded["error"]["message"] == message
      end
    end

    test "decodes error response with data field" do
      error = %{
        "code" => -32_602,
        "message" => "Invalid params",
        "data" => %{"details" => "missing required field 'name'", "field" => "name"}
      }

      json = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 5, "error" => error})
      {[decoded], ""} = Protocol.decode_message("#{json}\n")
      assert decoded["error"]["data"]["details"] == "missing required field 'name'"
      assert decoded["error"]["data"]["field"] == "name"
    end

    test "decodes error response with null data" do
      error = %{"code" => -32_603, "message" => "Internal error", "data" => nil}
      json = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "error" => error})
      {[decoded], ""} = Protocol.decode_message("#{json}\n")
      assert decoded["error"]["code"] == -32_603
      assert is_nil(decoded["error"]["data"])
    end
  end

  describe "empty tool list handling" do
    test "decodes tools/list response with empty tools array" do
      json = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{"tools" => []}})
      {[decoded], ""} = Protocol.decode_message("#{json}\n")
      assert decoded["result"]["tools"] == []
    end

    test "decodes tools/list response with no tools key" do
      json = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}})
      {[decoded], ""} = Protocol.decode_message("#{json}\n")
      assert decoded["result"] == %{}
      refute Map.has_key?(decoded["result"], "tools")
    end

    test "decodes tools/list response with null result" do
      json = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => nil})
      {[decoded], ""} = Protocol.decode_message("#{json}\n")
      assert is_nil(decoded["result"])
    end
  end

  describe "invalid JSON-RPC handling" do
    test "non-JSON line is treated as partial/incomplete" do
      {messages, rest} = Protocol.decode_message("this is not json\n")
      assert messages == []
      # The non-JSON line is retained as rest since it failed to parse
      assert rest == "this is not json"
    end

    test "empty JSON object is decoded as a message" do
      json = Jason.encode!(%{})
      {[decoded], ""} = Protocol.decode_message("#{json}\n")
      assert decoded == %{}
    end

    test "JSON array is not a valid JSON-RPC message but is decoded" do
      json = Jason.encode!([1, 2, 3])
      {[decoded], ""} = Protocol.decode_message("#{json}\n")
      assert decoded == [1, 2, 3]
    end

    test "message missing jsonrpc field is still decoded" do
      json = Jason.encode!(%{"id" => 1, "method" => "test"})
      {[decoded], ""} = Protocol.decode_message("#{json}\n")
      assert decoded["id"] == 1
      refute Map.has_key?(decoded, "jsonrpc")
    end

    test "message with string id is decoded" do
      json = Jason.encode!(%{"jsonrpc" => "2.0", "id" => "string-id", "result" => %{}})
      {[decoded], ""} = Protocol.decode_message("#{json}\n")
      assert decoded["id"] == "string-id"
    end

    test "multiple newlines between messages do not produce extra messages" do
      msg = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}})
      {messages, ""} = Protocol.decode_message("#{msg}\n\n\n")
      assert length(messages) == 1
    end

    test "only whitespace input produces no messages" do
      {messages, rest} = Protocol.decode_message("   \n  \n")
      assert messages == []
      # Whitespace lines fail JSON parse and the last one is kept as rest
      assert rest == "  "
    end

    test "truncated JSON is treated as partial" do
      {messages, rest} = Protocol.decode_message("{\"jsonrpc\":\"2.0\",\"id\":")
      assert messages == []
      assert rest == "{\"jsonrpc\":\"2.0\",\"id\":"
    end
  end

  describe "large message handling" do
    test "decodes a response with many tools" do
      tools =
        for i <- 1..100 do
          %{
            "name" => "tool_#{i}",
            "description" => "Description for tool #{i}",
            "inputSchema" => %{"type" => "object", "properties" => %{"arg" => %{"type" => "string"}}}
          }
        end

      json = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{"tools" => tools}})
      {[decoded], ""} = Protocol.decode_message("#{json}\n")
      assert length(decoded["result"]["tools"]) == 100
      assert Enum.at(decoded["result"]["tools"], 99)["name"] == "tool_100"
    end

    test "decodes a response with large text content" do
      large_text = String.duplicate("a", 100_000)
      result = %{"content" => [%{"type" => "text", "text" => large_text}]}
      json = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => result})
      {[decoded], ""} = Protocol.decode_message("#{json}\n")
      assert String.length(hd(decoded["result"]["content"])["text"]) == 100_000
    end
  end

  describe "encode_request/3 edge cases" do
    test "encodes with integer zero id" do
      {:ok, encoded} = Protocol.encode_request(0, "test/method")
      {[decoded], ""} = Protocol.decode_message(encoded)
      assert decoded["id"] == 0
    end

    test "encodes with negative id" do
      {:ok, encoded} = Protocol.encode_request(-1, "test/method")
      {[decoded], ""} = Protocol.decode_message(encoded)
      assert decoded["id"] == -1
    end

    test "encodes with very large id" do
      {:ok, encoded} = Protocol.encode_request(999_999_999, "test/method")
      {[decoded], ""} = Protocol.decode_message(encoded)
      assert decoded["id"] == 999_999_999
    end

    test "encodes method with special characters" do
      {:ok, encoded} = Protocol.encode_request(1, "$/cancelRequest")
      {[decoded], ""} = Protocol.decode_message(encoded)
      assert decoded["method"] == "$/cancelRequest"
    end

    test "encodes params with boolean and null values" do
      params = %{"enabled" => true, "disabled" => false, "value" => nil}
      {:ok, encoded} = Protocol.encode_request(1, "config/set", params)
      {[decoded], ""} = Protocol.decode_message(encoded)
      assert decoded["params"]["enabled"] == true
      assert decoded["params"]["disabled"] == false
      assert is_nil(decoded["params"]["value"])
    end

    test "encodes params with list values" do
      params = %{"items" => [1, "two", true, nil]}
      {:ok, encoded} = Protocol.encode_request(1, "batch", params)
      {[decoded], ""} = Protocol.decode_message(encoded)
      assert decoded["params"]["items"] == [1, "two", true, nil]
    end
  end
end
