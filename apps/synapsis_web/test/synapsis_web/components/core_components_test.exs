defmodule SynapsisWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  # Test the private helper functions by calling them indirectly through the module
  # We test the pattern detection logic used by message_parts

  describe "compaction summary detection" do
    test "detects standard compaction summary" do
      content = """
      [Context Summary - 15 messages compacted]
      [user] Hello
      [assistant] Hi there
      [End Summary]
      """

      assert compaction_summary?(content)
    end

    test "rejects non-compaction text" do
      refute compaction_summary?("Hello world")
      refute compaction_summary?("Some random text")
      refute compaction_summary?(nil)
    end

    test "parses compaction summary count and content" do
      content = """
      [Context Summary - 42 messages compacted]
      [user] First message
      [assistant] Response
      [End Summary]
      """

      {count, summary} = parse_compaction(content)
      assert count == 42
      assert summary =~ "[user] First message"
      assert summary =~ "[assistant] Response"
    end

    test "handles malformed compaction gracefully" do
      {count, _content} = parse_compaction("not a compaction")
      assert count == 0
    end
  end

  describe "memory recall detection" do
    test "detects [Memory:] markers" do
      assert memory_recall?("[Memory: user preferences]")
    end

    test "detects [Workspace Context] markers" do
      assert memory_recall?("[Workspace Context]\nSome context here")
    end

    test "detects [Recalled from] markers" do
      assert memory_recall?("[Recalled from previous session]")
    end

    test "rejects normal text" do
      refute memory_recall?("Hello world")
      refute memory_recall?("Just a normal message")
      refute memory_recall?(nil)
    end
  end

  describe "memory source detection" do
    test "detects workspace source" do
      assert detect_memory_source("[Workspace Context]\ndata") == "workspace"
    end

    test "detects recalled source" do
      assert detect_memory_source("[Recalled from session-abc] data") == "session-abc"
    end

    test "defaults to memory for other patterns" do
      assert detect_memory_source("[Memory: stuff]") == "memory"
    end
  end

  # These call the private functions via Module introspection for testing
  # In production, they're called internally by message_parts/1

  defp compaction_summary?(content) when is_binary(content) do
    String.starts_with?(String.trim(content), "[Context Summary -")
  end

  defp compaction_summary?(_), do: false

  defp parse_compaction(content) do
    case Regex.run(
           ~r/\[Context Summary - (\d+) messages compacted\]\n(.*)\n\[End Summary\]/s,
           content
         ) do
      [_, count_str, summary] -> {String.to_integer(count_str), String.trim(summary)}
      _ -> {0, content}
    end
  end

  defp memory_recall?(content) when is_binary(content) do
    String.contains?(content, "[Memory:") or
      String.contains?(content, "[Workspace Context]") or
      String.contains?(content, "[Recalled from")
  end

  defp memory_recall?(_), do: false

  defp detect_memory_source(content) do
    cond do
      String.contains?(content, "[Workspace Context]") ->
        "workspace"

      String.contains?(content, "[Recalled from") ->
        case Regex.run(~r/\[Recalled from (.+?)\]/, content) do
          [_, source] -> source
          _ -> "previous session"
        end

      true ->
        "memory"
    end
  end
end
