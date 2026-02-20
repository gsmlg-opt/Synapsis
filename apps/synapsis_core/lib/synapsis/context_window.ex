defmodule Synapsis.ContextWindow do
  @moduledoc "Pure functions for context window management."

  def needs_compaction?(messages, model_context_limit, opts_or_threshold \\ 0.8)

  def needs_compaction?(messages, model_context_limit, threshold) when is_float(threshold) do
    needs_compaction?(messages, model_context_limit, threshold: threshold)
  end

  def needs_compaction?(messages, model_context_limit, opts) when is_list(opts) do
    threshold = Keyword.get(opts, :threshold, 0.8)
    extra_tokens = Keyword.get(opts, :extra_tokens, 0)
    total = (messages |> Enum.map(& &1.token_count) |> Enum.sum()) + extra_tokens
    total > model_context_limit * threshold
  end

  def partition_for_compaction(messages, opts \\ []) do
    keep_recent = Keyword.get(opts, :keep_recent, 10)
    count = length(messages)

    if count <= keep_recent do
      {[], messages}
    else
      split_at = count - keep_recent
      Enum.split(messages, split_at)
    end
  end

  def estimate_tokens(text) when is_binary(text) do
    # Rough estimate: ~4 chars per token for English
    max(div(String.length(text), 4), 1)
  end

  def estimate_tokens(_), do: 0

  def total_tokens(messages) do
    messages |> Enum.map(& &1.token_count) |> Enum.sum()
  end
end
