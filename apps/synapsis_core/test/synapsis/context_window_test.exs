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
  end

  describe "estimate_tokens/1" do
    test "estimates token count from text" do
      assert ContextWindow.estimate_tokens("Hello world") > 0
    end

    test "returns 0 for nil" do
      assert ContextWindow.estimate_tokens(nil) == 0
    end
  end
end
