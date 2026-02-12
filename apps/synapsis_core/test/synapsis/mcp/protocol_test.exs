defmodule Synapsis.MCP.ProtocolTest do
  use ExUnit.Case, async: true

  alias Synapsis.MCP.Protocol

  describe "encode_request/3" do
    test "encodes a JSON-RPC request" do
      encoded = Protocol.encode_request(1, "tools/list")
      assert encoded =~ "\"jsonrpc\":\"2.0\""
      assert encoded =~ "\"id\":1"
      assert encoded =~ "\"method\":\"tools/list\""
      assert String.ends_with?(encoded, "\n")
    end
  end

  describe "encode_notification/2" do
    test "encodes a notification" do
      encoded = Protocol.encode_notification("notifications/initialized")
      assert encoded =~ "\"method\":\"notifications/initialized\""
      refute encoded =~ "\"id\""
    end
  end

  describe "decode_message/1" do
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
end
