defmodule Synapsis.Provider.ParserTest do
  use ExUnit.Case, async: true

  alias Synapsis.Provider.Parser

  describe "parse_chunk/2 Anthropic" do
    test "parses text_delta" do
      chunk = %{
        "type" => "content_block_delta",
        "delta" => %{"type" => "text_delta", "text" => "Hello"}
      }

      assert {:text_delta, "Hello"} = Parser.parse_chunk(chunk, :anthropic)
    end

    test "parses tool_use_start" do
      chunk = %{
        "type" => "content_block_start",
        "content_block" => %{"type" => "tool_use", "name" => "file_read", "id" => "toolu_123"}
      }

      assert {:tool_use_start, "file_read", "toolu_123"} = Parser.parse_chunk(chunk, :anthropic)
    end

    test "parses tool_input_delta" do
      chunk = %{
        "type" => "content_block_delta",
        "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"path\":"}
      }

      assert {:tool_input_delta, "{\"path\":"} = Parser.parse_chunk(chunk, :anthropic)
    end

    test "parses message_stop" do
      assert :done = Parser.parse_chunk(%{"type" => "message_stop"}, :anthropic)
    end

    test "parses ping as ignore" do
      assert :ignore = Parser.parse_chunk(%{"type" => "ping"}, :anthropic)
    end

    test "parses error" do
      chunk = %{"type" => "error", "error" => %{"type" => "overloaded_error"}}
      assert {:error, %{"type" => "overloaded_error"}} = Parser.parse_chunk(chunk, :anthropic)
    end
  end

  describe "parse_chunk/2 OpenAI" do
    test "parses text content" do
      chunk = %{"choices" => [%{"delta" => %{"content" => "Hi"}, "index" => 0}]}
      assert {:text_delta, "Hi"} = Parser.parse_chunk(chunk, :openai)
    end

    test "parses stop" do
      chunk = %{"choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]}
      assert :done = Parser.parse_chunk(chunk, :openai)
    end

    test "parses DONE string" do
      assert :done = Parser.parse_chunk("[DONE]", :openai)
    end

    test "parses tool_calls start" do
      chunk = %{
        "choices" => [
          %{
            "delta" => %{
              "tool_calls" => [
                %{"index" => 0, "id" => "call_123", "function" => %{"name" => "bash"}}
              ]
            }
          }
        ]
      }

      assert {:tool_use_start, "bash", "call_123"} = Parser.parse_chunk(chunk, :openai)
    end
  end

  describe "parse_chunk/2 Google" do
    test "parses text" do
      chunk = %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "Hello"}]}}]}
      assert {:text_delta, "Hello"} = Parser.parse_chunk(chunk, :google)
    end

    test "parses function call" do
      chunk = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{"functionCall" => %{"name" => "grep", "args" => %{"pattern" => "foo"}}}
              ]
            }
          }
        ]
      }

      assert {:tool_use_complete, "grep", %{"pattern" => "foo"}} =
               Parser.parse_chunk(chunk, :google)
    end

    test "parses stop" do
      chunk = %{"candidates" => [%{"finishReason" => "STOP"}]}
      assert :done = Parser.parse_chunk(chunk, :google)
    end
  end

  describe "parse_sse_lines/1" do
    test "parses standard SSE format" do
      data = """
      event: message_start
      data: {"type":"message_start"}

      data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}

      data: [DONE]
      """

      parsed = Parser.parse_sse_lines(data)
      assert length(parsed) == 3
      assert Enum.at(parsed, 0) == %{"type" => "message_start"}
      assert Enum.at(parsed, 2) == "[DONE]"
    end
  end
end
