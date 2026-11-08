defmodule Synapsis.Agent.Runtime.ProviderUsage do
  @moduledoc """
  Per-attempt provider observations mapped to native cumulative usage.

  Snapshots replace explicit counters; omitted snapshot fields retain earlier
  observations. Each delta occurrence adds its explicit numbers. Missing delta
  components remain unknown until a snapshot reanchors them. No provider event
  identity or retransmission deduplication is inferred.

  The relay buffers usage until normal completion: native Goal accounting cannot
  refund a prior charge after a cache revision, and an early unknown charge is
  sticky. This is a counter projection, not an accounting ledger or an assertion
  of authoritative provider capability.
  """

  @counters [
    :input_tokens,
    :output_tokens,
    :cache_read_tokens,
    :cache_write_tokens,
    :reasoning_tokens,
    :native_total
  ]

  def new do
    %{seen: false, source: nil, source_changed: false, status: nil, counters: empty_counters()}
  end

  def push(state, usage) when is_map(usage) do
    usage = if is_struct(usage), do: Map.from_struct(usage), else: usage

    counters =
      Map.new(@counters, fn key ->
        {key, observe(state.counters[key], usage[key], usage[:mode], state.seen)}
      end)

    %{
      state
      | seen: true,
        source: if(state.seen, do: state.source, else: usage[:source]),
        source_changed: state.source_changed or (state.seen and state.source != usage[:source]),
        status: usage[:status],
        counters: counters
    }
  end

  def snapshot(%{seen: false}), do: nil
  def snapshot(%{source_changed: true}), do: metrics(nil, nil, nil, nil)
  def snapshot(%{status: :unknown}), do: metrics(nil, nil, nil, nil)

  def snapshot(%{source: "anthropic", counters: usage}) do
    input = sum([usage.input_tokens, usage.cache_read_tokens, usage.cache_write_tokens])
    metrics(input, usage.cache_read_tokens, usage.output_tokens, usage.reasoning_tokens)
  end

  def snapshot(%{source: source, counters: usage})
      when source in ["openai", "openai_responses"] do
    metrics(
      usage.input_tokens,
      usage.cache_read_tokens,
      usage.output_tokens,
      usage.reasoning_tokens
    )
  end

  def snapshot(%{source: "google", counters: usage}) do
    output = sum([usage.output_tokens, usage.reasoning_tokens])

    input =
      case {usage.native_total, output} do
        {total, output} when is_integer(total) and is_integer(output) and total >= output ->
          derived = total - output
          if is_nil(usage.input_tokens) or derived >= usage.input_tokens, do: derived

        _ ->
          nil
      end

    metrics(input, usage.cache_read_tokens, output, usage.reasoning_tokens)
  end

  def snapshot(_), do: metrics(nil, nil, nil, nil)

  defp observe(_previous, value, :snapshot, _) when is_integer(value) and value >= 0, do: value
  defp observe(previous, nil, :snapshot, _), do: previous
  defp observe(_, value, :delta, false) when is_integer(value) and value >= 0, do: value

  defp observe(previous, value, :delta, true)
       when is_integer(previous) and is_integer(value) and value >= 0,
       do: previous + value

  defp observe(_, _, _, _), do: nil

  defp sum(values) do
    if Enum.all?(values, &(is_integer(&1) and &1 >= 0)), do: Enum.sum(values)
  end

  defp metrics(input, cached, output, reasoning),
    do: %{
      input_tokens: input,
      cached_tokens: cached,
      output_tokens: output,
      reasoning_tokens: reasoning
    }

  defp empty_counters, do: Map.new(@counters, &{&1, nil})
end
