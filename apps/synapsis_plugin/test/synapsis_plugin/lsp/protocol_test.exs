defmodule SynapsisPlugin.LSP.ProtocolTest do
  use ExUnit.Case, async: true

  alias SynapsisPlugin.LSP.Protocol

  describe "encode_request/3" do
    test "produces valid Content-Length framed JSON-RPC" do
      encoded = Protocol.encode_request(1, "initialize", %{"rootUri" => "file:///tmp"})
      assert encoded =~ "Content-Length:"
      assert encoded =~ "\r\n\r\n"

      # Extract and parse the JSON body
      [_header, body] = String.split(encoded, "\r\n\r\n", parts: 2)
      assert {:ok, decoded} = Jason.decode(body)
      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 1
      assert decoded["method"] == "initialize"
      assert decoded["params"]["rootUri"] == "file:///tmp"
    end

    test "Content-Length matches the body byte size" do
      encoded = Protocol.encode_request(42, "textDocument/didOpen", %{"uri" => "file:///test.ex"})
      [header, body] = String.split(encoded, "\r\n\r\n", parts: 2)
      "Content-Length: " <> len_str = header
      assert String.to_integer(len_str) == byte_size(body)
    end

    test "encodes textDocument/definition request" do
      params = %{
        "textDocument" => %{"uri" => "file:///tmp/app.ex"},
        "position" => %{"line" => 10, "character" => 5}
      }

      encoded = Protocol.encode_request(3, "textDocument/definition", params)
      [_header, body] = String.split(encoded, "\r\n\r\n", parts: 2)
      {:ok, decoded} = Jason.decode(body)
      assert decoded["method"] == "textDocument/definition"
      assert decoded["params"]["position"]["line"] == 10
    end

    test "encodes textDocument/references request" do
      params = %{
        "textDocument" => %{"uri" => "file:///tmp/mod.ex"},
        "position" => %{"line" => 5, "character" => 8},
        "context" => %{"includeDeclaration" => true}
      }

      encoded = Protocol.encode_request(4, "textDocument/references", params)
      [_header, body] = String.split(encoded, "\r\n\r\n", parts: 2)
      {:ok, decoded} = Jason.decode(body)
      assert decoded["method"] == "textDocument/references"
      assert decoded["params"]["context"]["includeDeclaration"] == true
    end

    test "increments id correctly across multiple requests" do
      r1 = Protocol.encode_request(1, "method1", %{})
      r2 = Protocol.encode_request(2, "method2", %{})

      [_, b1] = String.split(r1, "\r\n\r\n", parts: 2)
      [_, b2] = String.split(r2, "\r\n\r\n", parts: 2)

      {:ok, d1} = Jason.decode(b1)
      {:ok, d2} = Jason.decode(b2)

      assert d1["id"] == 1
      assert d2["id"] == 2
    end
  end

  describe "encode_notification/2" do
    test "produces Content-Length framed notification without id" do
      encoded = Protocol.encode_notification("initialized", %{})
      assert encoded =~ "Content-Length:"
      assert encoded =~ "\r\n\r\n"

      [_header, body] = String.split(encoded, "\r\n\r\n", parts: 2)
      {:ok, decoded} = Jason.decode(body)
      assert decoded["jsonrpc"] == "2.0"
      assert decoded["method"] == "initialized"
      refute Map.has_key?(decoded, "id")
    end

    test "encodes textDocument/didOpen notification" do
      params = %{
        "textDocument" => %{
          "uri" => "file:///tmp/test.ex",
          "languageId" => "elixir",
          "version" => 1,
          "text" => "defmodule Test do\nend\n"
        }
      }

      encoded = Protocol.encode_notification("textDocument/didOpen", params)
      [_header, body] = String.split(encoded, "\r\n\r\n", parts: 2)
      {:ok, decoded} = Jason.decode(body)
      assert decoded["method"] == "textDocument/didOpen"
      assert decoded["params"]["textDocument"]["languageId"] == "elixir"
    end

    test "encodes textDocument/didChange notification" do
      params = %{
        "textDocument" => %{"uri" => "file:///tmp/test.ex", "version" => 2},
        "contentChanges" => [%{"text" => "new content"}]
      }

      encoded = Protocol.encode_notification("textDocument/didChange", params)
      [_header, body] = String.split(encoded, "\r\n\r\n", parts: 2)
      {:ok, decoded} = Jason.decode(body)
      assert decoded["method"] == "textDocument/didChange"
      assert hd(decoded["params"]["contentChanges"])["text"] == "new content"
    end
  end

  describe "decode_message/1" do
    test "decodes a complete message" do
      json = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "test", "params" => %{}})
      data = "Content-Length: #{byte_size(json)}\r\n\r\n#{json}"
      assert {:ok, msg, ""} = Protocol.decode_message(data)
      assert msg["method"] == "test"
      assert msg["jsonrpc"] == "2.0"
    end

    test "decodes an initialize response" do
      result = %{
        "capabilities" => %{
          "textDocumentSync" => 1,
          "completionProvider" => %{"triggerCharacters" => ["."]}
        }
      }

      json = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => result})
      data = "Content-Length: #{byte_size(json)}\r\n\r\n#{json}"
      assert {:ok, msg, ""} = Protocol.decode_message(data)
      assert msg["id"] == 1
      assert msg["result"]["capabilities"]["textDocumentSync"] == 1
    end

    test "decodes a publishDiagnostics notification" do
      diag = %{
        "range" => %{
          "start" => %{"line" => 5, "character" => 0},
          "end" => %{"line" => 5, "character" => 10}
        },
        "severity" => 1,
        "message" => "undefined function foo/0"
      }

      params = %{
        "uri" => "file:///tmp/test.ex",
        "diagnostics" => [diag]
      }

      json =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "textDocument/publishDiagnostics",
          "params" => params
        })

      data = "Content-Length: #{byte_size(json)}\r\n\r\n#{json}"
      assert {:ok, msg, ""} = Protocol.decode_message(data)
      assert msg["method"] == "textDocument/publishDiagnostics"
      assert hd(msg["params"]["diagnostics"])["severity"] == 1
    end

    test "returns :incomplete for partial header" do
      assert :incomplete = Protocol.decode_message("Content-")
    end

    test "returns :incomplete for partial body" do
      assert :incomplete = Protocol.decode_message("Content-Length: 100\r\n\r\n{")
    end

    test "returns :incomplete for empty data" do
      assert :incomplete = Protocol.decode_message("")
    end

    test "handles multiple messages in sequence" do
      json1 = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}})
      json2 = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notify", "params" => %{}})

      data =
        "Content-Length: #{byte_size(json1)}\r\n\r\n#{json1}" <>
          "Content-Length: #{byte_size(json2)}\r\n\r\n#{json2}"

      assert {:ok, msg1, rest} = Protocol.decode_message(data)
      assert msg1["id"] == 1
      assert {:ok, msg2, ""} = Protocol.decode_message(rest)
      assert msg2["method"] == "notify"
    end

    test "returns rest data after decoding first message" do
      json = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}})
      trailing = "Content-Length: 50\r\n\r\n{partial"

      data = "Content-Length: #{byte_size(json)}\r\n\r\n#{json}#{trailing}"
      assert {:ok, msg, rest} = Protocol.decode_message(data)
      assert msg["id"] == 1
      assert rest == trailing
    end
  end
end
