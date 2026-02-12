defmodule Synapsis.LSP.ProtocolTest do
  use ExUnit.Case, async: true

  alias Synapsis.LSP.Protocol

  describe "encode_request/3" do
    test "encodes a valid JSON-RPC request with Content-Length" do
      encoded = Protocol.encode_request(1, "initialize", %{"rootUri" => "file:///tmp"})
      assert encoded =~ "Content-Length:"
      assert encoded =~ "\"jsonrpc\":\"2.0\""
      assert encoded =~ "\"id\":1"
      assert encoded =~ "\"method\":\"initialize\""
    end
  end

  describe "encode_notification/2" do
    test "encodes a notification without id" do
      encoded = Protocol.encode_notification("initialized", %{})
      assert encoded =~ "Content-Length:"
      refute encoded =~ "\"id\""
      assert encoded =~ "\"method\":\"initialized\""
    end
  end

  describe "decode_message/1" do
    test "decodes a complete message" do
      json = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "test", "params" => %{}})
      data = "Content-Length: #{byte_size(json)}\r\n\r\n#{json}"
      assert {:ok, msg, ""} = Protocol.decode_message(data)
      assert msg["method"] == "test"
    end

    test "returns incomplete for partial data" do
      assert :incomplete = Protocol.decode_message("Content-Length: 100\r\n\r\n{")
    end

    test "handles multiple messages" do
      json1 = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}})
      json2 = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notify", "params" => %{}})

      data =
        "Content-Length: #{byte_size(json1)}\r\n\r\n#{json1}Content-Length: #{byte_size(json2)}\r\n\r\n#{json2}"

      assert {:ok, msg1, rest} = Protocol.decode_message(data)
      assert msg1["id"] == 1
      assert {:ok, msg2, ""} = Protocol.decode_message(rest)
      assert msg2["method"] == "notify"
    end
  end
end
