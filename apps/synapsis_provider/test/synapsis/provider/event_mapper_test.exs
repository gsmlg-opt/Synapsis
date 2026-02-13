defmodule Synapsis.Provider.EventMapperTest do
  use ExUnit.Case, async: true

  alias Synapsis.Provider.EventMapper

  # ---------------------------------------------------------------------------
  # Anthropic events
  # ---------------------------------------------------------------------------

  describe "map_event/2 Anthropic" do
    test "parses text_start" do
      chunk = %{"type" => "content_block_start", "content_block" => %{"type" => "text", "text" => ""}}
      assert :text_start = EventMapper.map_event(:anthropic, chunk)
    end

    test "parses text_delta" do
      chunk = %{
        "type" => "content_block_delta",
        "delta" => %{"type" => "text_delta", "text" => "Hello"}
      }

      assert {:text_delta, "Hello"} = EventMapper.map_event(:anthropic, chunk)
    end

    test "parses tool_use_start" do
      chunk = %{
        "type" => "content_block_start",
        "content_block" => %{"type" => "tool_use", "name" => "file_read", "id" => "toolu_123"}
      }

      assert {:tool_use_start, "file_read", "toolu_123"} = EventMapper.map_event(:anthropic, chunk)
    end

    test "parses tool_input_delta" do
      chunk = %{
        "type" => "content_block_delta",
        "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"path\":"}
      }

      assert {:tool_input_delta, "{\"path\":"} = EventMapper.map_event(:anthropic, chunk)
    end

    test "parses reasoning_start" do
      chunk = %{"type" => "content_block_start", "content_block" => %{"type" => "thinking"}}
      assert :reasoning_start = EventMapper.map_event(:anthropic, chunk)
    end

    test "parses reasoning_delta" do
      chunk = %{
        "type" => "content_block_delta",
        "delta" => %{"type" => "thinking_delta", "thinking" => "Let me think..."}
      }

      assert {:reasoning_delta, "Let me think..."} = EventMapper.map_event(:anthropic, chunk)
    end

    test "parses content_block_stop" do
      assert :content_block_stop = EventMapper.map_event(:anthropic, %{"type" => "content_block_stop"})
    end

    test "parses message_start" do
      assert :message_start = EventMapper.map_event(:anthropic, %{"type" => "message_start"})
    end

    test "parses message_delta" do
      chunk = %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}}
      assert {:message_delta, %{"stop_reason" => "end_turn"}} = EventMapper.map_event(:anthropic, chunk)
    end

    test "parses message_stop as done" do
      assert :done = EventMapper.map_event(:anthropic, %{"type" => "message_stop"})
    end

    test "parses ping as ignore" do
      assert :ignore = EventMapper.map_event(:anthropic, %{"type" => "ping"})
    end

    test "parses error" do
      chunk = %{"type" => "error", "error" => %{"type" => "overloaded_error"}}
      assert {:error, %{"type" => "overloaded_error"}} = EventMapper.map_event(:anthropic, chunk)
    end

    test "unknown events return ignore" do
      assert :ignore = EventMapper.map_event(:anthropic, %{"type" => "unknown"})
    end
  end

  # ---------------------------------------------------------------------------
  # OpenAI events
  # ---------------------------------------------------------------------------

  describe "map_event/2 OpenAI" do
    test "parses text content" do
      chunk = %{"choices" => [%{"delta" => %{"content" => "Hi"}, "index" => 0}]}
      assert {:text_delta, "Hi"} = EventMapper.map_event(:openai, chunk)
    end

    test "parses stop finish_reason" do
      chunk = %{"choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]}
      assert :done = EventMapper.map_event(:openai, chunk)
    end

    test "parses end_turn finish_reason" do
      chunk = %{"choices" => [%{"delta" => %{}, "finish_reason" => "end_turn"}]}
      assert :done = EventMapper.map_event(:openai, chunk)
    end

    test "parses tool_calls finish_reason" do
      chunk = %{"choices" => [%{"delta" => %{}, "finish_reason" => "tool_calls"}]}
      assert :done = EventMapper.map_event(:openai, chunk)
    end

    test "parses [DONE] string" do
      assert :done = EventMapper.map_event(:openai, "[DONE]")
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

      assert {:tool_use_start, "bash", "call_123"} = EventMapper.map_event(:openai, chunk)
    end

    test "parses tool_calls arguments delta" do
      chunk = %{
        "choices" => [
          %{
            "delta" => %{
              "tool_calls" => [
                %{"function" => %{"arguments" => "{\"command\":"}}
              ]
            }
          }
        ]
      }

      assert {:tool_input_delta, "{\"command\":"} = EventMapper.map_event(:openai, chunk)
    end

    test "parses reasoning_content" do
      chunk = %{
        "choices" => [%{"delta" => %{"reasoning_content" => "thinking deeply"}, "index" => 0}]
      }

      assert {:reasoning_delta, "thinking deeply"} = EventMapper.map_event(:openai, chunk)
    end

    test "unknown events return ignore" do
      assert :ignore = EventMapper.map_event(:openai, %{"object" => "chat.completion.chunk"})
    end
  end

  # ---------------------------------------------------------------------------
  # Google events
  # ---------------------------------------------------------------------------

  describe "map_event/2 Google" do
    test "parses text" do
      chunk = %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "Hello"}]}}]}
      assert {:text_delta, "Hello"} = EventMapper.map_event(:google, chunk)
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
               EventMapper.map_event(:google, chunk)
    end

    test "parses STOP finish reason" do
      chunk = %{"candidates" => [%{"finishReason" => "STOP"}]}
      assert :done = EventMapper.map_event(:google, chunk)
    end

    test "unknown events return ignore" do
      assert :ignore = EventMapper.map_event(:google, %{"usageMetadata" => %{}})
    end
  end
end
