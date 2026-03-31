defmodule SynapsisWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  alias SynapsisWeb.MessageHelpers

  describe "compaction summary detection" do
    test "detects standard compaction summary" do
      content = """
      [Context Summary - 15 messages compacted]
      [user] Hello
      [assistant] Hi there
      [End Summary]
      """

      assert MessageHelpers.compaction_summary?(content)
    end

    test "rejects non-compaction text" do
      refute MessageHelpers.compaction_summary?("Hello world")
      refute MessageHelpers.compaction_summary?("Some random text")
      refute MessageHelpers.compaction_summary?(nil)
    end

    test "parses compaction summary count and content" do
      content = """
      [Context Summary - 42 messages compacted]
      [user] First message
      [assistant] Response
      [End Summary]
      """

      {count, summary} = MessageHelpers.parse_compaction(content)
      assert count == 42
      assert summary =~ "[user] First message"
      assert summary =~ "[assistant] Response"
    end

    test "handles malformed compaction gracefully" do
      {count, _content} = MessageHelpers.parse_compaction("not a compaction")
      assert count == 0
    end
  end

  describe "memory recall detection" do
    test "detects [Memory:] markers" do
      assert MessageHelpers.memory_recall?("[Memory: user preferences]")
    end

    test "detects [Workspace Context] markers" do
      assert MessageHelpers.memory_recall?("[Workspace Context]\nSome context here")
    end

    test "detects [Recalled from] markers" do
      assert MessageHelpers.memory_recall?("[Recalled from previous session]")
    end

    test "rejects normal text" do
      refute MessageHelpers.memory_recall?("Hello world")
      refute MessageHelpers.memory_recall?("Just a normal message")
      refute MessageHelpers.memory_recall?(nil)
    end
  end

  describe "memory source detection" do
    test "detects workspace source" do
      assert MessageHelpers.detect_memory_source("[Workspace Context]\ndata") == "workspace"
    end

    test "detects recalled source" do
      assert MessageHelpers.detect_memory_source("[Recalled from session-abc] data") ==
               "session-abc"
    end

    test "defaults to memory for other patterns" do
      assert MessageHelpers.detect_memory_source("[Memory: stuff]") == "memory"
    end
  end
end
