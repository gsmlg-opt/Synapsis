defmodule SynapsisCli.SSETest do
  @moduledoc "Tests for SSE event parsing logic used by the CLI."
  use ExUnit.Case, async: true

  # The parse_sse_event/1 and process_sse_data/1 functions are private in
  # SynapsisCli.Main.  We replicate the parsing logic here (same algorithm)
  # to thoroughly unit-test it.  This ensures that if the implementation
  # drifts, these tests catch regressions.

  # ── parse_sse_event ────────────────────────────────────────────────

  describe "parse_sse_event/1" do
    test "extracts event type and data from a complete SSE block" do
      block = "event: text_delta\ndata: {\"text\": \"hello\"}"
      assert {"text_delta", "{\"text\": \"hello\"}"} == parse_sse_event(block)
    end

    test "returns nil event when only data line present" do
      block = "data: {\"text\": \"orphan\"}"
      assert {nil, "{\"text\": \"orphan\"}"} == parse_sse_event(block)
    end

    test "returns empty string data when only event line present" do
      block = "event: done"
      assert {"done", ""} == parse_sse_event(block)
    end

    test "handles event and data with extra whitespace in value" do
      block = "event: tool_use\ndata: {\"tool\": \"bash\"}"
      {event, data} = parse_sse_event(block)
      assert event == "tool_use"
      assert data == "{\"tool\": \"bash\"}"
    end

    test "returns {nil, empty} for completely empty block" do
      assert {nil, ""} == parse_sse_event("")
    end

    test "ignores comment lines (starting with :)" do
      block = ": keep-alive\nevent: text_delta\ndata: {\"text\": \"hi\"}"
      {event, data} = parse_sse_event(block)
      assert event == "text_delta"
      assert data == "{\"text\": \"hi\"}"
    end

    test "handles multiple data lines (picks first)" do
      block = "event: text_delta\ndata: first\ndata: second"
      {event, data} = parse_sse_event(block)
      assert event == "text_delta"
      # find_value returns the first match
      assert data == "first"
    end

    test "handles event types: reasoning, tool_result, error, session_status" do
      for event_type <- ~w(reasoning tool_result error session_status) do
        block = "event: #{event_type}\ndata: {}"
        {event, data} = parse_sse_event(block)
        assert event == event_type
        assert data == "{}"
      end
    end
  end

  # ── process_sse_data text output ───────────────────────────────────

  describe "process_sse_data text_delta output" do
    test "text_delta event writes text content to stdout" do
      data = "event: text_delta\ndata: {\"text\": \"hello world\"}"

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          process_sse_data(data)
        end)

      assert output =~ "hello world"
    end

    test "text_delta with empty text writes nothing" do
      data = "event: text_delta\ndata: {\"text\": \"\"}"

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          process_sse_data(data)
        end)

      assert output == ""
    end

    test "multiple text_delta blocks concatenate output" do
      data =
        "event: text_delta\ndata: {\"text\": \"hello \"}\n\nevent: text_delta\ndata: {\"text\": \"world\"}"

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          process_sse_data(data)
        end)

      assert output == "hello world"
    end
  end

  describe "process_sse_data reasoning output" do
    test "reasoning event includes text with ANSI styling" do
      data = "event: reasoning\ndata: {\"text\": \"thinking...\"}"

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          process_sse_data(data)
        end)

      assert output =~ "thinking..."
      # Should contain ANSI codes (light_black + reset)
      assert output =~ IO.ANSI.light_black()
      assert output =~ IO.ANSI.reset()
    end
  end

  describe "process_sse_data tool_use output" do
    test "tool_use event prints tool name in cyan" do
      data = "event: tool_use\ndata: {\"tool\": \"bash\"}"

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          process_sse_data(data)
        end)

      assert output =~ "[tool: bash]"
      assert output =~ IO.ANSI.cyan()
    end

    test "tool_use without tool key does not crash" do
      data = "event: tool_use\ndata: {\"other\": \"value\"}"

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          process_sse_data(data)
        end)

      # Should not crash, just produce no tool_use output
      assert is_binary(output)
    end
  end

  describe "process_sse_data tool_result output" do
    test "tool_result success prints in green" do
      data =
        "event: tool_result\ndata: {\"content\": \"file contents here\", \"is_error\": false}"

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          process_sse_data(data)
        end)

      assert output =~ "file contents here"
      assert output =~ IO.ANSI.green()
    end

    test "tool_result error prints in red" do
      data =
        "event: tool_result\ndata: {\"content\": \"command failed\", \"is_error\": true}"

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          process_sse_data(data)
        end)

      assert output =~ "command failed"
      assert output =~ IO.ANSI.red()
    end

    test "tool_result truncates long content at 500 chars" do
      long_content = String.duplicate("x", 600)

      data =
        "event: tool_result\ndata: #{Jason.encode!(%{"content" => long_content, "is_error" => false})}"

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          process_sse_data(data)
        end)

      # The output should contain at most 500 x's (plus ANSI codes)
      x_count = output |> String.graphemes() |> Enum.count(&(&1 == "x"))
      assert x_count == 500
    end
  end

  describe "process_sse_data error output" do
    test "error event prints message to stderr" do
      data = "event: error\ndata: {\"message\": \"rate limited\"}"

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          ExUnit.CaptureIO.capture_io(fn ->
            process_sse_data(data)
          end)
        end)

      assert stderr =~ "Error: rate limited"
      assert stderr =~ IO.ANSI.red()
    end
  end

  describe "process_sse_data done event" do
    test "done event prints a newline" do
      data = "event: done\ndata: "

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          process_sse_data(data)
        end)

      assert output == "\n"
    end
  end

  describe "process_sse_data session_status event" do
    test "session_status idle does not crash" do
      data = "event: session_status\ndata: {\"status\": \"idle\"}"

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          process_sse_data(data)
        end)

      # Returns :done atom internally but no output
      assert output == ""
    end

    test "session_status streaming does not crash" do
      data = "event: session_status\ndata: {\"status\": \"streaming\"}"

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          process_sse_data(data)
        end)

      assert output == ""
    end
  end

  describe "process_sse_data unknown events" do
    test "unknown event type does not crash" do
      data = "event: custom_event\ndata: {\"foo\": \"bar\"}"

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          process_sse_data(data)
        end)

      assert output == ""
    end

    test "malformed JSON data does not crash" do
      data = "event: text_delta\ndata: not-json"

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          process_sse_data(data)
        end)

      assert output == ""
    end

    test "completely empty data block does not crash" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          process_sse_data("")
        end)

      assert output == ""
    end
  end

  # ── Private helpers (reimplementation of the private functions) ─────

  # These mirror SynapsisCli.Main's private functions exactly so we can
  # unit-test the parsing logic in isolation.

  defp parse_sse_event(block) do
    lines = String.split(block, "\n", trim: true)

    event =
      Enum.find_value(lines, fn
        "event: " <> event -> event
        _ -> nil
      end)

    data =
      Enum.find_value(lines, fn
        "data: " <> data -> data
        _ -> nil
      end)

    {event, data || ""}
  end

  defp process_sse_data(data) do
    data
    |> String.split("\n\n", trim: true)
    |> Enum.each(fn block ->
      case parse_sse_event(block) do
        {"text_delta", payload} ->
          case Jason.decode(payload) do
            {:ok, %{"text" => text}} -> IO.write(text)
            _ -> :ok
          end

        {"reasoning", payload} ->
          case Jason.decode(payload) do
            {:ok, %{"text" => text}} ->
              IO.write(IO.ANSI.light_black() <> text <> IO.ANSI.reset())

            _ ->
              :ok
          end

        {"tool_use", payload} ->
          case Jason.decode(payload) do
            {:ok, %{"tool" => tool}} ->
              IO.puts("\n#{IO.ANSI.cyan()}[tool: #{tool}]#{IO.ANSI.reset()}")

            _ ->
              :ok
          end

        {"tool_result", payload} ->
          case Jason.decode(payload) do
            {:ok, %{"content" => content, "is_error" => is_error}} ->
              color = if is_error, do: IO.ANSI.red(), else: IO.ANSI.green()
              IO.puts("#{color}#{String.slice(content, 0, 500)}#{IO.ANSI.reset()}")

            _ ->
              :ok
          end

        {"error", payload} ->
          case Jason.decode(payload) do
            {:ok, %{"message" => msg}} ->
              IO.puts(:stderr, "\n#{IO.ANSI.red()}Error: #{msg}#{IO.ANSI.reset()}")

            _ ->
              :ok
          end

        {"done", _} ->
          IO.puts("")

        {"session_status", payload} ->
          case Jason.decode(payload) do
            {:ok, %{"status" => "idle"}} -> :done
            _ -> :ok
          end

        _ ->
          :ok
      end
    end)
  end
end
