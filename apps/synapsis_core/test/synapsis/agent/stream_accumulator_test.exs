defmodule Synapsis.Agent.StreamAccumulatorTest do
  use ExUnit.Case, async: true

  alias Synapsis.Agent.StreamAccumulator

  setup do
    {:ok, acc: StreamAccumulator.new()}
  end

  describe "accumulate/2" do
    test "text_delta appends to pending_text", %{acc: acc} do
      {broadcasts, acc} = StreamAccumulator.accumulate({:text_delta, "hello"}, acc)
      assert acc.pending_text == "hello"
      assert [{"text_delta", %{text: "hello"}}] = broadcasts

      {broadcasts, acc} = StreamAccumulator.accumulate({:text_delta, " world"}, acc)
      assert acc.pending_text == "hello world"
      assert [{"text_delta", %{text: " world"}}] = broadcasts
    end

    test "tool_use_start creates pending_tool_use", %{acc: acc} do
      {broadcasts, acc} =
        StreamAccumulator.accumulate({:tool_use_start, "file_read", "tu_1"}, acc)

      assert acc.pending_tool_use == %{tool: "file_read", tool_use_id: "tu_1"}
      assert acc.pending_tool_input == ""
      assert [{"tool_use", %{tool: "file_read", tool_use_id: "tu_1"}}] = broadcasts
    end

    test "tool_input_delta appends to pending_tool_input", %{acc: acc} do
      {_, acc} = StreamAccumulator.accumulate({:tool_use_start, "file_read", "tu_1"}, acc)
      {broadcasts, acc} = StreamAccumulator.accumulate({:tool_input_delta, ~s({"path")}, acc)
      assert acc.pending_tool_input == ~s({"path")
      assert broadcasts == []

      {_, acc} = StreamAccumulator.accumulate({:tool_input_delta, ~s(: "/foo"})}, acc)
      assert acc.pending_tool_input == ~s({"path": "/foo"})
    end

    test "content_block_stop flushes pending tool_use", %{acc: acc} do
      {_, acc} = StreamAccumulator.accumulate({:tool_use_start, "file_read", "tu_1"}, acc)
      {_, acc} = StreamAccumulator.accumulate({:tool_input_delta, ~s({"path": "/foo"})}, acc)
      {broadcasts, acc} = StreamAccumulator.accumulate(:content_block_stop, acc)

      assert broadcasts == []
      assert acc.pending_tool_use == nil
      assert acc.pending_tool_input == ""
      assert [tool_use] = acc.tool_uses
      assert tool_use.tool == "file_read"
      assert tool_use.tool_use_id == "tu_1"
      assert tool_use.input == %{"path" => "/foo"}
    end

    test "tool_use_complete pushes to tool_uses list", %{acc: acc} do
      {_, acc} =
        StreamAccumulator.accumulate(
          {:tool_use_complete, "grep", %{"pattern" => "foo"}},
          acc
        )

      assert [tu] = acc.tool_uses
      assert tu.tool == "grep"
      assert tu.input == %{"pattern" => "foo"}
    end

    test "accumulates concurrent OpenAI tool_call deltas by index", %{acc: acc} do
      events = [
        {:tool_call_delta, 0, "call_1", "mcp:backplane:web::search",
         ~s({"query": "trending Python repositories on GitHub today"})},
        {:tool_call_delta, 1, "call_2", "mcp:backplane:web::search",
         ~s({"query": "trending Rust repositories on GitHub today"})},
        {:tool_call_delta, 2, "call_3", "mcp:backplane:web::search",
         ~s({"query": "trending Zig repositories on GitHub today"})},
        {:tool_call_delta, 3, "call_4", "mcp:backplane:web::search",
         ~s({"query": "trending Erlang repositories on GitHub today"})},
        {:tool_call_delta, 4, "call_5", "mcp:backplane:web::search", "{"},
        {:tool_call_delta, 4, nil, nil, ~s("query": "trending Go repositories on GitHub today"})}
      ]

      {broadcasts, acc} =
        Enum.reduce(events, {[], acc}, fn event, {all_broadcasts, acc} ->
          {broadcasts, acc} = StreamAccumulator.accumulate(event, acc)
          {all_broadcasts ++ broadcasts, acc}
        end)

      assert [
               {"tool_use", %{tool: "mcp:backplane:web::search", tool_use_id: "call_1"}},
               {"tool_use", %{tool: "mcp:backplane:web::search", tool_use_id: "call_2"}},
               {"tool_use", %{tool: "mcp:backplane:web::search", tool_use_id: "call_3"}},
               {"tool_use", %{tool: "mcp:backplane:web::search", tool_use_id: "call_4"}},
               {"tool_use", %{tool: "mcp:backplane:web::search", tool_use_id: "call_5"}}
             ] = broadcasts

      {_, acc} = StreamAccumulator.accumulate(:done, acc)

      assert [
               %{
                 tool_use_id: "call_1",
                 input: %{"query" => "trending Python repositories on GitHub today"}
               },
               %{
                 tool_use_id: "call_2",
                 input: %{"query" => "trending Rust repositories on GitHub today"}
               },
               %{
                 tool_use_id: "call_3",
                 input: %{"query" => "trending Zig repositories on GitHub today"}
               },
               %{
                 tool_use_id: "call_4",
                 input: %{"query" => "trending Erlang repositories on GitHub today"}
               },
               %{
                 tool_use_id: "call_5",
                 input: %{"query" => "trending Go repositories on GitHub today"}
               }
             ] = acc.tool_uses
    end

    test "reasoning_delta appends to pending_reasoning", %{acc: acc} do
      {broadcasts, acc} = StreamAccumulator.accumulate({:reasoning_delta, "thinking..."}, acc)
      assert acc.pending_reasoning == "thinking..."
      assert [{"reasoning", %{text: "thinking..."}}] = broadcasts
    end

    test "reasoning_signature_delta appends to pending_reasoning_signature", %{acc: acc} do
      {broadcasts, acc} =
        StreamAccumulator.accumulate({:reasoning_signature_delta, "sig-123"}, acc)

      assert acc.pending_reasoning_signature == "sig-123"
      assert broadcasts == []
    end

    test "handles interleaved text and tool events", %{acc: acc} do
      {_, acc} = StreamAccumulator.accumulate({:text_delta, "Let me read "}, acc)
      {_, acc} = StreamAccumulator.accumulate({:tool_use_start, "file_read", "tu_1"}, acc)
      {_, acc} = StreamAccumulator.accumulate({:tool_input_delta, ~s({"path":"/a"})}, acc)
      {_, acc} = StreamAccumulator.accumulate(:content_block_stop, acc)
      {_, acc} = StreamAccumulator.accumulate({:text_delta, "and also"}, acc)

      assert acc.pending_text == "Let me read and also"
      assert length(acc.tool_uses) == 1
      assert hd(acc.tool_uses).tool == "file_read"
    end

    test "handles multiple tool_use blocks in sequence", %{acc: acc} do
      {_, acc} = StreamAccumulator.accumulate({:tool_use_start, "file_read", "tu_1"}, acc)
      {_, acc} = StreamAccumulator.accumulate({:tool_input_delta, ~s({"path":"/a"})}, acc)
      {_, acc} = StreamAccumulator.accumulate(:content_block_stop, acc)
      {_, acc} = StreamAccumulator.accumulate({:tool_use_start, "grep", "tu_2"}, acc)
      {_, acc} = StreamAccumulator.accumulate({:tool_input_delta, ~s({"pattern":"x"})}, acc)
      {_, acc} = StreamAccumulator.accumulate(:content_block_stop, acc)

      assert length(acc.tool_uses) == 2
      assert Enum.at(acc.tool_uses, 0).tool == "file_read"
      assert Enum.at(acc.tool_uses, 1).tool == "grep"
    end

    test "ignores :message_start, :message_delta, :ignore", %{acc: acc} do
      for event <- [:message_start, {:message_delta, %{}}, :ignore] do
        {broadcasts, new_acc} = StreamAccumulator.accumulate(event, acc)
        assert broadcasts == []
        assert new_acc == acc
      end
    end

    test ":done is no-op without pending tool_use", %{acc: acc} do
      {broadcasts, new_acc} = StreamAccumulator.accumulate(:done, acc)
      assert broadcasts == []
      assert new_acc == acc
    end

    test ":done finalizes pending tool_use into tool_uses", %{acc: acc} do
      {_, acc} = StreamAccumulator.accumulate({:tool_use_start, "file_read", "tu_1"}, acc)
      {_, acc} = StreamAccumulator.accumulate({:tool_input_delta, ~s({"path": "/foo"})}, acc)

      # No content_block_stop — stream ends directly with :done
      {broadcasts, acc} = StreamAccumulator.accumulate(:done, acc)

      assert broadcasts == []
      assert acc.pending_tool_use == nil
      assert acc.pending_tool_input == ""
      assert [tool_use] = acc.tool_uses
      assert tool_use.tool == "file_read"
      assert tool_use.tool_use_id == "tu_1"
      assert tool_use.input == %{"path" => "/foo"}
      assert tool_use.status == :pending
    end

    test ":done preserves already-finalized tools and finalizes the last", %{acc: acc} do
      # First tool: properly closed with content_block_stop
      {_, acc} = StreamAccumulator.accumulate({:tool_use_start, "file_read", "tu_1"}, acc)
      {_, acc} = StreamAccumulator.accumulate({:tool_input_delta, ~s({"path":"/a"})}, acc)
      {_, acc} = StreamAccumulator.accumulate(:content_block_stop, acc)

      # Second tool: missing content_block_stop, stream ends
      {_, acc} = StreamAccumulator.accumulate({:tool_use_start, "grep", "tu_2"}, acc)
      {_, acc} = StreamAccumulator.accumulate({:tool_input_delta, ~s({"pattern":"x"})}, acc)
      {_, acc} = StreamAccumulator.accumulate(:done, acc)

      assert length(acc.tool_uses) == 2
      assert Enum.at(acc.tool_uses, 0).tool == "file_read"
      assert Enum.at(acc.tool_uses, 1).tool == "grep"
      assert Enum.at(acc.tool_uses, 1).input == %{"pattern" => "x"}
    end

    test ":done handles invalid JSON in pending_tool_input", %{acc: acc} do
      {_, acc} = StreamAccumulator.accumulate({:tool_use_start, "file_read", "tu_1"}, acc)
      {_, acc} = StreamAccumulator.accumulate({:tool_input_delta, "not valid json"}, acc)
      {_, acc} = StreamAccumulator.accumulate(:done, acc)

      assert [tool_use] = acc.tool_uses
      assert tool_use.input == %{}
    end

    test "content_block_stop without pending tool_use is no-op", %{acc: acc} do
      {broadcasts, new_acc} = StreamAccumulator.accumulate(:content_block_stop, acc)
      assert broadcasts == []
      assert new_acc == acc
    end

    test "error event produces error broadcast", %{acc: acc} do
      {broadcasts, _acc} =
        StreamAccumulator.accumulate({:error, %{"message" => "rate limited"}}, acc)

      assert [{"error", %{message: "rate limited"}}] = broadcasts
    end
  end

  describe "new/0" do
    test "returns empty accumulator" do
      acc = StreamAccumulator.new()
      assert acc.pending_text == ""
      assert acc.pending_tool_use == nil
      assert acc.pending_tool_input == ""
      assert acc.pending_tool_calls == %{}
      assert acc.pending_reasoning == ""
      assert acc.pending_reasoning_signature == ""
      assert acc.tool_uses == []
    end
  end
end
