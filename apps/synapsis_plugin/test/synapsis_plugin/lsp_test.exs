defmodule SynapsisPlugin.LSPTest do
  use ExUnit.Case, async: true

  alias SynapsisPlugin.LSP.Protocol

  describe "LSP Protocol" do
    test "encodes a valid JSON-RPC request with Content-Length" do
      encoded = Protocol.encode_request(1, "initialize", %{"rootUri" => "file:///tmp"})
      assert encoded =~ "Content-Length:"
      assert encoded =~ "\"jsonrpc\":\"2.0\""
      assert encoded =~ "\"id\":1"
      assert encoded =~ "\"method\":\"initialize\""
    end

    test "encodes a notification without id" do
      encoded = Protocol.encode_notification("initialized", %{})
      assert encoded =~ "Content-Length:"
      refute encoded =~ "\"id\""
      assert encoded =~ "\"method\":\"initialized\""
    end

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

  describe "LSP tools" do
    test "provides 5 LSP tools" do
      state = %SynapsisPlugin.LSP{
        port: nil,
        language: "elixir",
        root_path: "/tmp",
        request_id: 1,
        pending: %{},
        buffer: "",
        initialized: false,
        diagnostics: %{},
        pending_requests: %{}
      }

      tools = SynapsisPlugin.LSP.tools(state)
      assert length(tools) == 5

      tool_names = Enum.map(tools, & &1.name)
      assert "lsp_diagnostics" in tool_names
      assert "lsp_definition" in tool_names
      assert "lsp_references" in tool_names
      assert "lsp_hover" in tool_names
      assert "lsp_symbols" in tool_names
    end

    test "lsp_diagnostics returns from state" do
      state = %SynapsisPlugin.LSP{
        port: nil,
        language: "elixir",
        root_path: "/tmp",
        request_id: 1,
        pending: %{},
        buffer: "",
        initialized: true,
        diagnostics: %{
          "file:///tmp/test.ex" => [
            %{
              "range" => %{"start" => %{"line" => 5}},
              "severity" => 1,
              "message" => "undefined function foo/0"
            }
          ]
        },
        pending_requests: %{}
      }

      assert {:ok, result, _state} = SynapsisPlugin.LSP.execute("lsp_diagnostics", %{}, state)
      assert result =~ "error"
      assert result =~ "undefined function foo/0"
    end
  end

  describe "LSP Manager" do
    test "detects elixir from .ex files" do
      languages =
        SynapsisPlugin.LSP.Manager.detect_languages(Path.expand("../../..", __DIR__))

      assert "elixir" in languages
    end

    test "returns empty for nonexistent directory" do
      languages =
        SynapsisPlugin.LSP.Manager.detect_languages(
          "/tmp/nonexistent_#{:rand.uniform(100_000)}"
        )

      assert languages == []
    end
  end

  describe "LSP Position" do
    test "finds symbol in file" do
      tmp_file = Path.join(System.tmp_dir!(), "lsp_pos_test_#{:rand.uniform(100_000)}.ex")
      File.write!(tmp_file, "defmodule MyModule do\n  def hello, do: :world\nend\n")

      assert {:ok, %{line: 0, character: col}} =
               SynapsisPlugin.LSP.Position.find_symbol(tmp_file, "MyModule")

      assert col > 0

      assert {:ok, %{line: 1, character: _}} =
               SynapsisPlugin.LSP.Position.find_symbol(tmp_file, "hello")

      assert {:error, :not_found} =
               SynapsisPlugin.LSP.Position.find_symbol(tmp_file, "nonexistent")

      File.rm!(tmp_file)
    end
  end
end
