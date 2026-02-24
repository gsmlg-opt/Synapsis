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
  end
end
