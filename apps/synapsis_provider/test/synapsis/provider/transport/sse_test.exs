defmodule Synapsis.Provider.Transport.SSETest do
  use ExUnit.Case, async: true

  alias Synapsis.Provider.Transport.SSE

  describe "parse_lines/1" do
    test "parses standard SSE data lines" do
      data = """
      data: {"type":"message_start"}

      data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}

      """

      parsed = SSE.parse_lines(data)
      assert length(parsed) == 2
      assert Enum.at(parsed, 0) == %{"type" => "message_start"}

      assert Enum.at(parsed, 1) == %{
               "type" => "content_block_delta",
               "delta" => %{"type" => "text_delta", "text" => "Hi"}
             }
    end

    test "handles [DONE] sentinel" do
      data = "data: [DONE]\n"
      assert ["[DONE]"] = SSE.parse_lines(data)
    end

    test "handles [DONE] with trailing content" do
      data = "data: [DONE] extra\n"
      assert ["[DONE]"] = SSE.parse_lines(data)
    end

    test "ignores non-data lines" do
      data = """
      event: message_start
      data: {"type":"message_start"}
      : comment
      id: 123
      """

      parsed = SSE.parse_lines(data)
      assert length(parsed) == 1
      assert Enum.at(parsed, 0) == %{"type" => "message_start"}
    end

    test "ignores malformed JSON" do
      data = "data: {invalid json}\n"
      assert [] = SSE.parse_lines(data)
    end

    test "handles multiple events in one chunk" do
      data = """
      data: {"type":"ping"}
      data: {"type":"content_block_start","content_block":{"type":"text"}}
      data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}
      data: {"type":"message_stop"}
      """

      parsed = SSE.parse_lines(data)
      assert length(parsed) == 4
    end

    test "handles empty input" do
      assert [] = SSE.parse_lines("")
    end

    test "handles data: with no space before JSON" do
      data = "data:{\"type\":\"ping\"}\n"
      parsed = SSE.parse_lines(data)
      assert length(parsed) == 1
      assert Enum.at(parsed, 0) == %{"type" => "ping"}
    end

    test "handles multiple newlines between events" do
      data = "data: {\"type\":\"ping\"}\n\n\n\ndata: {\"type\":\"message_stop\"}\n\n\n"
      parsed = SSE.parse_lines(data)
      assert length(parsed) == 2
      assert Enum.at(parsed, 0) == %{"type" => "ping"}
      assert Enum.at(parsed, 1) == %{"type" => "message_stop"}
    end

    test "handles data with trailing whitespace" do
      data = "data: {\"type\":\"ping\"}   \n"
      parsed = SSE.parse_lines(data)
      assert length(parsed) == 1
      assert Enum.at(parsed, 0) == %{"type" => "ping"}
    end

    test "handles data: prefix with extra spaces" do
      data = "data:  {\"type\":\"ping\"}\n"
      parsed = SSE.parse_lines(data)
      assert length(parsed) == 1
      assert Enum.at(parsed, 0) == %{"type" => "ping"}
    end

    test "ignores lines with id: field" do
      data = "id: 42\ndata: {\"type\":\"ping\"}\n"
      parsed = SSE.parse_lines(data)
      assert length(parsed) == 1
      assert Enum.at(parsed, 0) == %{"type" => "ping"}
    end

    test "ignores id: field with empty value" do
      data = "id:\ndata: {\"type\":\"ping\"}\n"
      parsed = SSE.parse_lines(data)
      assert length(parsed) == 1
      assert Enum.at(parsed, 0) == %{"type" => "ping"}
    end

    test "ignores event: field lines" do
      data = "event: message_start\ndata: {\"type\":\"message_start\"}\n"
      parsed = SSE.parse_lines(data)
      assert length(parsed) == 1
      assert Enum.at(parsed, 0) == %{"type" => "message_start"}
    end

    test "ignores event: field with custom event name" do
      data = "event: custom_event\ndata: {\"type\":\"custom\"}\n"
      parsed = SSE.parse_lines(data)
      assert length(parsed) == 1
      assert Enum.at(parsed, 0) == %{"type" => "custom"}
    end

    test "ignores empty event: field" do
      data = "event:\ndata: {\"type\":\"ping\"}\n"
      parsed = SSE.parse_lines(data)
      assert length(parsed) == 1
      assert Enum.at(parsed, 0) == %{"type" => "ping"}
    end

    test "ignores comment lines starting with colon" do
      data = ": this is a comment\ndata: {\"type\":\"ping\"}\n"
      parsed = SSE.parse_lines(data)
      assert length(parsed) == 1
      assert Enum.at(parsed, 0) == %{"type" => "ping"}
    end

    test "ignores multiple comment lines" do
      data = ": comment 1\n: comment 2\n: comment 3\ndata: {\"type\":\"ping\"}\n"
      parsed = SSE.parse_lines(data)
      assert length(parsed) == 1
      assert Enum.at(parsed, 0) == %{"type" => "ping"}
    end

    test "ignores bare colon comment with no text" do
      data = ":\ndata: {\"type\":\"ping\"}\n"
      parsed = SSE.parse_lines(data)
      assert length(parsed) == 1
      assert Enum.at(parsed, 0) == %{"type" => "ping"}
    end

    test "ignores retry: field" do
      data = "retry: 5000\ndata: {\"type\":\"ping\"}\n"
      parsed = SSE.parse_lines(data)
      assert length(parsed) == 1
      assert Enum.at(parsed, 0) == %{"type" => "ping"}
    end

    test "ignores retry: field with empty value" do
      data = "retry:\ndata: {\"type\":\"ping\"}\n"
      parsed = SSE.parse_lines(data)
      assert length(parsed) == 1
      assert Enum.at(parsed, 0) == %{"type" => "ping"}
    end

    test "handles full SSE event with all fields" do
      data = """
      : keep-alive comment
      id: evt-001
      event: content_block_delta
      retry: 3000
      data: {"type":"content_block_delta","delta":{"text":"hello"}}
      """

      parsed = SSE.parse_lines(data)
      assert length(parsed) == 1

      assert Enum.at(parsed, 0) == %{
               "type" => "content_block_delta",
               "delta" => %{"text" => "hello"}
             }
    end

    test "data: line with only whitespace after prefix is not valid JSON" do
      data = "data:   \n"
      parsed = SSE.parse_lines(data)
      assert parsed == []
    end

    test "data: line with empty string JSON" do
      data = "data: \"\"\n"
      parsed = SSE.parse_lines(data)
      assert parsed == [""]
    end

    test "data: line with JSON array" do
      data = "data: [1, 2, 3]\n"
      parsed = SSE.parse_lines(data)
      assert parsed == [[1, 2, 3]]
    end

    test "data: line with JSON number" do
      data = "data: 42\n"
      parsed = SSE.parse_lines(data)
      assert parsed == [42]
    end

    test "data: line with nested JSON object" do
      data = "data: {\"outer\":{\"inner\":{\"deep\":true}}}\n"
      parsed = SSE.parse_lines(data)
      assert length(parsed) == 1
      assert Enum.at(parsed, 0) == %{"outer" => %{"inner" => %{"deep" => true}}}
    end

    test "interleaved comments and data lines" do
      data = """
      : heartbeat
      data: {"type":"start"}
      : another heartbeat
      data: {"type":"delta"}
      : final heartbeat
      data: {"type":"stop"}
      """

      parsed = SSE.parse_lines(data)
      assert length(parsed) == 3
      assert Enum.at(parsed, 0) == %{"type" => "start"}
      assert Enum.at(parsed, 1) == %{"type" => "delta"}
      assert Enum.at(parsed, 2) == %{"type" => "stop"}
    end

    test "multiple data: lines are parsed independently (not concatenated)" do
      # Per the SSE spec, multiple data: lines in one event should be concatenated.
      # Our parser treats each line independently since it is a simple line-by-line parser.
      data = "data: {\"part\":1}\ndata: {\"part\":2}\n"
      parsed = SSE.parse_lines(data)
      assert length(parsed) == 2
      assert Enum.at(parsed, 0) == %{"part" => 1}
      assert Enum.at(parsed, 1) == %{"part" => 2}
    end

    test "data line with [DONE] among other data lines" do
      data = "data: {\"type\":\"delta\"}\ndata: [DONE]\n"
      parsed = SSE.parse_lines(data)
      assert length(parsed) == 2
      assert Enum.at(parsed, 0) == %{"type" => "delta"}
      assert Enum.at(parsed, 1) == "[DONE]"
    end

    test "only whitespace input returns empty list" do
      assert [] = SSE.parse_lines("   \n  \n\n")
    end

    test "unknown field names are ignored" do
      data = "foo: bar\nbaz: qux\ndata: {\"type\":\"ping\"}\n"
      parsed = SSE.parse_lines(data)
      assert length(parsed) == 1
      assert Enum.at(parsed, 0) == %{"type" => "ping"}
    end
  end
end
