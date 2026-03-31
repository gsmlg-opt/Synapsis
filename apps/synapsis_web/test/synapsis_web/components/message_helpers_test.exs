defmodule SynapsisWeb.MessageHelpersTest do
  use ExUnit.Case, async: true

  alias SynapsisWeb.MessageHelpers

  describe "compaction_summary?/1" do
    test "returns true for valid compaction summary" do
      assert MessageHelpers.compaction_summary?(
               "[Context Summary - 42 messages compacted]\nSummary text\n[End Summary]"
             )
    end

    test "returns true with leading whitespace" do
      assert MessageHelpers.compaction_summary?(
               "  [Context Summary - 10 messages compacted]\ntext\n[End Summary]"
             )
    end

    test "returns false for regular text" do
      refute MessageHelpers.compaction_summary?("Hello, how can I help?")
    end

    test "returns false for nil" do
      refute MessageHelpers.compaction_summary?(nil)
    end

    test "returns false for non-string" do
      refute MessageHelpers.compaction_summary?(42)
    end
  end

  describe "parse_compaction/1" do
    test "extracts count and summary from valid compaction" do
      content =
        "[Context Summary - 42 messages compacted]\nThis is the summary text\n[End Summary]"

      assert {42, "This is the summary text"} = MessageHelpers.parse_compaction(content)
    end

    test "returns {0, content} for non-matching content" do
      assert {0, "Hello"} = MessageHelpers.parse_compaction("Hello")
    end
  end

  describe "memory_recall?/1" do
    test "detects [Memory: ...] marker" do
      assert MessageHelpers.memory_recall?("[Memory: user prefers dark mode]")
    end

    test "detects [Workspace Context] marker" do
      assert MessageHelpers.memory_recall?("[Workspace Context] soul.md loaded")
    end

    test "detects [Recalled from ...] marker" do
      assert MessageHelpers.memory_recall?("[Recalled from previous session] user name is Jon")
    end

    test "returns false for regular text" do
      refute MessageHelpers.memory_recall?("Just a normal message")
    end

    test "returns false for nil" do
      refute MessageHelpers.memory_recall?(nil)
    end
  end

  describe "detect_memory_source/1" do
    test "returns workspace for workspace context" do
      assert "workspace" = MessageHelpers.detect_memory_source("[Workspace Context] data")
    end

    test "extracts source from recalled marker" do
      assert "session-abc" =
               MessageHelpers.detect_memory_source("[Recalled from session-abc] data")
    end

    test "returns previous session for malformed recalled marker" do
      assert "previous session" =
               MessageHelpers.detect_memory_source("[Recalled from] incomplete")
    end

    test "returns memory as default" do
      assert "memory" = MessageHelpers.detect_memory_source("[Memory: some fact]")
    end
  end
end
