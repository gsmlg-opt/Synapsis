defmodule Synapsis.ContextWindowTest do
  use ExUnit.Case, async: true

  alias Synapsis.ContextWindow

  describe "needs_compaction?/3" do
    test "returns false when under threshold" do
      messages = [%{token_count: 1000}, %{token_count: 2000}]
      refute ContextWindow.needs_compaction?(messages, 100_000)
    end

    test "returns true when over threshold" do
      messages = [%{token_count: 50_000}, %{token_count: 40_000}]
      assert ContextWindow.needs_compaction?(messages, 100_000)
    end

    test "extra_tokens tips budget over threshold" do
      # Messages alone are under threshold (30k / 100k = 30%)
      messages = [%{token_count: 30_000}]
      refute ContextWindow.needs_compaction?(messages, 100_000)

      # But with 55k extra tokens (failure log), total = 85k > 80k threshold
      assert ContextWindow.needs_compaction?(messages, 100_000, extra_tokens: 55_000)
    end

    test "accepts legacy float threshold argument" do
      messages = [%{token_count: 50_000}, %{token_count: 40_000}]
      assert ContextWindow.needs_compaction?(messages, 100_000, 0.8)
    end
  end

  describe "partition_for_compaction/2" do
    test "splits messages keeping recent" do
      messages = Enum.map(1..20, fn i -> %{id: i, token_count: 100} end)
      {to_compact, to_keep} = ContextWindow.partition_for_compaction(messages, keep_recent: 5)
      assert length(to_compact) == 15
      assert length(to_keep) == 5
    end

    test "keeps all when fewer than keep_recent" do
      messages = [%{id: 1, token_count: 100}]
      {to_compact, to_keep} = ContextWindow.partition_for_compaction(messages, keep_recent: 10)
      assert to_compact == []
      assert length(to_keep) == 1
    end

    test "keeps all when count equals keep_recent exactly" do
      messages = Enum.map(1..5, fn i -> %{id: i, token_count: 100} end)
      {to_compact, to_keep} = ContextWindow.partition_for_compaction(messages, keep_recent: 5)
      assert to_compact == []
      assert length(to_keep) == 5
    end
  end

  describe "estimate_tokens/1" do
    test "estimates token count from text" do
      assert ContextWindow.estimate_tokens("Hello world") > 0
    end

    test "returns 0 for nil" do
      assert ContextWindow.estimate_tokens(nil) == 0
    end

    test "returns at least 1 for non-empty string" do
      assert ContextWindow.estimate_tokens("x") >= 1
    end

    test "returns 0 for non-binary" do
      assert ContextWindow.estimate_tokens(42) == 0
      assert ContextWindow.estimate_tokens([]) == 0
    end
  end

  describe "total_tokens/1" do
    test "sums token counts" do
      messages = [%{token_count: 100}, %{token_count: 200}, %{token_count: 50}]
      assert ContextWindow.total_tokens(messages) == 350
    end

    test "returns 0 for empty list" do
      assert ContextWindow.total_tokens([]) == 0
    end
  end

  describe "needs_compaction?/3 edge cases" do
    test "returns false for empty messages list" do
      refute ContextWindow.needs_compaction?([], 100_000)
    end

    test "custom threshold option" do
      messages = [%{token_count: 60_000}]
      # 60% < 80% default → false
      refute ContextWindow.needs_compaction?(messages, 100_000)
      # 60% > 50% custom threshold → true
      assert ContextWindow.needs_compaction?(messages, 100_000, threshold: 0.5)
    end
  end
end
