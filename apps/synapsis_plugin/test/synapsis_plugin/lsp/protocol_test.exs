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

  describe "encode/decode round-trip" do
    test "request round-trips through encode then decode" do
      encoded = Protocol.encode_request(10, "textDocument/completion", %{
        "textDocument" => %{"uri" => "file:///project/main.ex"},
        "position" => %{"line" => 20, "character" => 15}
      })

      assert {:ok, decoded, ""} = Protocol.decode_message(encoded)
      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 10
      assert decoded["method"] == "textDocument/completion"
      assert decoded["params"]["position"]["line"] == 20
    end

    test "notification round-trips through encode then decode" do
      encoded = Protocol.encode_notification("textDocument/didSave", %{
        "textDocument" => %{"uri" => "file:///project/app.ex"}
      })

      assert {:ok, decoded, ""} = Protocol.decode_message(encoded)
      assert decoded["jsonrpc"] == "2.0"
      assert decoded["method"] == "textDocument/didSave"
      assert decoded["params"]["textDocument"]["uri"] == "file:///project/app.ex"
      refute Map.has_key?(decoded, "id")
    end

    test "request with unicode content round-trips" do
      encoded = Protocol.encode_request(1, "textDocument/hover", %{
        "text" => "Hello, \u4e16\u754c! \u{1F600}"
      })

      assert {:ok, decoded, ""} = Protocol.decode_message(encoded)
      assert decoded["params"]["text"] == "Hello, \u4e16\u754c! \u{1F600}"
    end

    test "request with empty params round-trips" do
      encoded = Protocol.encode_request(99, "shutdown", %{})
      assert {:ok, decoded, ""} = Protocol.decode_message(encoded)
      assert decoded["id"] == 99
      assert decoded["method"] == "shutdown"
      assert decoded["params"] == %{}
    end
  end

  describe "encode_notification/2 edge cases" do
    test "encodes textDocument/didClose notification" do
      params = %{
        "textDocument" => %{"uri" => "file:///tmp/closed.ex"}
      }

      encoded = Protocol.encode_notification("textDocument/didClose", params)
      [_header, body] = String.split(encoded, "\r\n\r\n", parts: 2)
      {:ok, decoded} = Jason.decode(body)
      assert decoded["method"] == "textDocument/didClose"
      assert decoded["params"]["textDocument"]["uri"] == "file:///tmp/closed.ex"
      refute Map.has_key?(decoded, "id")
    end

    test "encodes textDocument/didSave notification" do
      params = %{
        "textDocument" => %{"uri" => "file:///project/saved.ex"},
        "text" => "defmodule Saved do\nend\n"
      }

      encoded = Protocol.encode_notification("textDocument/didSave", params)
      [_header, body] = String.split(encoded, "\r\n\r\n", parts: 2)
      {:ok, decoded} = Jason.decode(body)
      assert decoded["method"] == "textDocument/didSave"
      assert decoded["params"]["text"] == "defmodule Saved do\nend\n"
    end

    test "encodes initialized notification with empty params" do
      encoded = Protocol.encode_notification("initialized", %{})
      [header, body] = String.split(encoded, "\r\n\r\n", parts: 2)
      "Content-Length: " <> len_str = header
      assert String.to_integer(len_str) == byte_size(body)
      {:ok, decoded} = Jason.decode(body)
      assert decoded["method"] == "initialized"
      assert decoded["params"] == %{}
    end

    test "encodes exit notification" do
      encoded = Protocol.encode_notification("exit", %{})
      assert {:ok, decoded, ""} = Protocol.decode_message(encoded)
      assert decoded["method"] == "exit"
    end

    test "Content-Length is correct for notification with multi-byte characters" do
      params = %{"text" => "\u00e9\u00e8\u00ea\u00eb"}
      encoded = Protocol.encode_notification("test/unicode", params)
      [header, body] = String.split(encoded, "\r\n\r\n", parts: 2)
      "Content-Length: " <> len_str = header
      assert String.to_integer(len_str) == byte_size(body)
    end
  end

  describe "diagnostics parsing with various severity levels" do
    test "decodes diagnostics with severity 1 (error)" do
      diag = diagnostic(1, "undefined function bar/0", 10, 0, 10, 5)
      msg = diagnostics_message("file:///app/lib/foo.ex", [diag])
      assert {:ok, decoded, ""} = Protocol.decode_message(msg)
      assert hd(decoded["params"]["diagnostics"])["severity"] == 1
    end

    test "decodes diagnostics with severity 2 (warning)" do
      diag = diagnostic(2, "variable x is unused", 3, 2, 3, 3)
      msg = diagnostics_message("file:///app/lib/bar.ex", [diag])
      assert {:ok, decoded, ""} = Protocol.decode_message(msg)
      assert hd(decoded["params"]["diagnostics"])["severity"] == 2
    end

    test "decodes diagnostics with severity 3 (information)" do
      diag = diagnostic(3, "consider using Enum.map/2", 7, 0, 7, 20)
      msg = diagnostics_message("file:///app/lib/baz.ex", [diag])
      assert {:ok, decoded, ""} = Protocol.decode_message(msg)
      assert hd(decoded["params"]["diagnostics"])["severity"] == 3
    end

    test "decodes diagnostics with severity 4 (hint)" do
      diag = diagnostic(4, "unused alias", 1, 0, 1, 15)
      msg = diagnostics_message("file:///app/lib/hint.ex", [diag])
      assert {:ok, decoded, ""} = Protocol.decode_message(msg)
      assert hd(decoded["params"]["diagnostics"])["severity"] == 4
    end

    test "decodes multiple diagnostics with mixed severities" do
      diags = [
        diagnostic(1, "error message", 1, 0, 1, 5),
        diagnostic(2, "warning message", 5, 0, 5, 10),
        diagnostic(3, "info message", 10, 0, 10, 8),
        diagnostic(4, "hint message", 15, 0, 15, 3)
      ]

      msg = diagnostics_message("file:///app/lib/mixed.ex", diags)
      assert {:ok, decoded, ""} = Protocol.decode_message(msg)
      parsed_diags = decoded["params"]["diagnostics"]
      assert length(parsed_diags) == 4
      severities = Enum.map(parsed_diags, & &1["severity"])
      assert severities == [1, 2, 3, 4]
    end

    test "decodes diagnostics with empty diagnostics list (file is clean)" do
      msg = diagnostics_message("file:///app/lib/clean.ex", [])
      assert {:ok, decoded, ""} = Protocol.decode_message(msg)
      assert decoded["params"]["diagnostics"] == []
      assert decoded["params"]["uri"] == "file:///app/lib/clean.ex"
    end

    test "decodes diagnostics with source and code fields" do
      diag = %{
        "range" => %{
          "start" => %{"line" => 2, "character" => 0},
          "end" => %{"line" => 2, "character" => 10}
        },
        "severity" => 1,
        "source" => "elixir-ls",
        "code" => "E001",
        "message" => "module attribute not found"
      }

      msg = diagnostics_message("file:///app/lib/attr.ex", [diag])
      assert {:ok, decoded, ""} = Protocol.decode_message(msg)
      d = hd(decoded["params"]["diagnostics"])
      assert d["source"] == "elixir-ls"
      assert d["code"] == "E001"
    end

    test "decodes diagnostics with relatedInformation" do
      diag = %{
        "range" => %{
          "start" => %{"line" => 5, "character" => 0},
          "end" => %{"line" => 5, "character" => 10}
        },
        "severity" => 1,
        "message" => "type mismatch",
        "relatedInformation" => [
          %{
            "location" => %{
              "uri" => "file:///app/lib/other.ex",
              "range" => %{
                "start" => %{"line" => 10, "character" => 0},
                "end" => %{"line" => 10, "character" => 5}
              }
            },
            "message" => "defined here"
          }
        ]
      }

      msg = diagnostics_message("file:///app/lib/type.ex", [diag])
      assert {:ok, decoded, ""} = Protocol.decode_message(msg)
      related = hd(decoded["params"]["diagnostics"])["relatedInformation"]
      assert length(related) == 1
      assert hd(related)["message"] == "defined here"
    end
  end

  describe "invalid messages handling" do
    test "returns error for malformed JSON body" do
      bad_body = "{not valid json!!}"
      data = "Content-Length: #{byte_size(bad_body)}\r\n\r\n#{bad_body}"
      assert {:error, :invalid_json} = Protocol.decode_message(data)
    end

    test "returns incomplete for Content-Length with zero" do
      data = "Content-Length: 0\r\n\r\n"
      # Zero-length body is technically empty string, which is invalid JSON
      assert {:error, :invalid_json} = Protocol.decode_message(data)
    end

    test "returns incomplete for missing Content-Length header" do
      assert :incomplete = Protocol.decode_message("{\"jsonrpc\":\"2.0\"}")
    end

    test "returns incomplete for header without CRLF separator" do
      assert :incomplete = Protocol.decode_message("Content-Length: 10\n\n{}")
    end

    test "returns incomplete for only CRLF" do
      assert :incomplete = Protocol.decode_message("\r\n\r\n")
    end

    test "returns incomplete for just the header prefix" do
      assert :incomplete = Protocol.decode_message("Content-")
    end

    test "returns incomplete for header with body shorter than Content-Length" do
      assert :incomplete = Protocol.decode_message("Content-Length: 1000\r\n\r\n{\"small\":1}")
    end

    test "handles body with trailing garbage after valid JSON" do
      json = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}})
      # The Content-Length covers exactly the JSON, so trailing data is rest
      trailing = "GARBAGE"
      data = "Content-Length: #{byte_size(json)}\r\n\r\n#{json}#{trailing}"
      assert {:ok, msg, rest} = Protocol.decode_message(data)
      assert msg["id"] == 1
      assert rest == trailing
    end
  end

  describe "encode_request/3 edge cases" do
    test "Content-Length is correct for multi-byte UTF-8 characters" do
      params = %{"text" => "\u00e9l\u00e8ve \u{1F600}"}
      encoded = Protocol.encode_request(1, "test", params)
      [header, body] = String.split(encoded, "\r\n\r\n", parts: 2)
      "Content-Length: " <> len_str = header
      assert String.to_integer(len_str) == byte_size(body)
    end

    test "encodes with zero id" do
      encoded = Protocol.encode_request(0, "shutdown", %{})
      assert {:ok, decoded, ""} = Protocol.decode_message(encoded)
      assert decoded["id"] == 0
    end

    test "encodes with very large id" do
      encoded = Protocol.encode_request(999_999_999, "test", %{})
      assert {:ok, decoded, ""} = Protocol.decode_message(encoded)
      assert decoded["id"] == 999_999_999
    end

    test "encodes with deeply nested params" do
      params = %{
        "level1" => %{
          "level2" => %{
            "level3" => %{
              "value" => "deep"
            }
          }
        }
      }

      encoded = Protocol.encode_request(1, "deep/test", params)
      assert {:ok, decoded, ""} = Protocol.decode_message(encoded)
      assert get_in(decoded, ["params", "level1", "level2", "level3", "value"]) == "deep"
    end

    test "encodes $/cancelRequest method" do
      encoded = Protocol.encode_request(1, "$/cancelRequest", %{"id" => 5})
      assert {:ok, decoded, ""} = Protocol.decode_message(encoded)
      assert decoded["method"] == "$/cancelRequest"
      assert decoded["params"]["id"] == 5
    end
  end

  describe "sequential decode of multiple messages" do
    test "decodes three messages sequentially from a buffer" do
      json1 = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{"status" => "ok"}})
      json2 = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "textDocument/publishDiagnostics",
                              "params" => %{"uri" => "file:///a.ex", "diagnostics" => []}})
      json3 = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 2, "result" => nil})

      data =
        "Content-Length: #{byte_size(json1)}\r\n\r\n#{json1}" <>
        "Content-Length: #{byte_size(json2)}\r\n\r\n#{json2}" <>
        "Content-Length: #{byte_size(json3)}\r\n\r\n#{json3}"

      assert {:ok, msg1, rest1} = Protocol.decode_message(data)
      assert msg1["id"] == 1

      assert {:ok, msg2, rest2} = Protocol.decode_message(rest1)
      assert msg2["method"] == "textDocument/publishDiagnostics"

      assert {:ok, msg3, ""} = Protocol.decode_message(rest2)
      assert msg3["id"] == 2
      assert is_nil(msg3["result"])
    end

    test "decodes two messages followed by incomplete data" do
      json1 = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}})
      json2 = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 2, "result" => %{}})

      data =
        "Content-Length: #{byte_size(json1)}\r\n\r\n#{json1}" <>
        "Content-Length: #{byte_size(json2)}\r\n\r\n#{json2}" <>
        "Content-Length: 500\r\n\r\n{partial"

      assert {:ok, _msg1, rest1} = Protocol.decode_message(data)
      assert {:ok, _msg2, rest2} = Protocol.decode_message(rest1)
      assert :incomplete = Protocol.decode_message(rest2)
    end
  end

  # Helper to build a Content-Length framed publishDiagnostics notification
  defp diagnostics_message(uri, diagnostics) do
    json =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "textDocument/publishDiagnostics",
        "params" => %{
          "uri" => uri,
          "diagnostics" => diagnostics
        }
      })

    "Content-Length: #{byte_size(json)}\r\n\r\n#{json}"
  end

  defp diagnostic(severity, message, start_line, start_char, end_line, end_char) do
    %{
      "range" => %{
        "start" => %{"line" => start_line, "character" => start_char},
        "end" => %{"line" => end_line, "character" => end_char}
      },
      "severity" => severity,
      "message" => message
    }
  end
end
