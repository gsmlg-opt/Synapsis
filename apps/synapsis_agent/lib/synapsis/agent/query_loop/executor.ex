defmodule Synapsis.Agent.QueryLoop.Executor do
  @moduledoc """
  Concurrency-partitioned tool executor for the query loop.

  Partitions tool calls into batches: consecutive read-only tools run in parallel,
  everything else runs serially. Executes batches in order.
  """

  require Logger

  @type tool_block :: %{id: String.t(), name: String.t(), input: map()}
  @type batch :: {:concurrent, [tool_block()]} | {:serial, [tool_block()]}

  @concurrent_permission_levels [:none, :read]

  @doc """
  Partition tool blocks into concurrent and serial batches.

  Consecutive concurrency-safe tools (permission_level :none or :read) are grouped.
  Non-safe tools each get their own serial batch.
  """
  @spec partition([tool_block()], map()) :: [batch()]
  def partition([], _tool_map), do: []

  def partition(blocks, tool_map) do
    blocks
    |> Enum.reduce([], fn block, acc ->
      safe? = concurrent_safe?(block.name, tool_map)
      append_to_batches(acc, block, safe?)
    end)
    |> Enum.reverse()
  end

  defp concurrent_safe?(name, tool_map) do
    case Map.get(tool_map, name) do
      nil ->
        false

      mod ->
        level =
          if function_exported?(mod, :permission_level, 0),
            do: mod.permission_level(),
            else: :write

        level in @concurrent_permission_levels
    end
  end

  defp append_to_batches([{:concurrent, items} | rest], block, true) do
    [{:concurrent, items ++ [block]} | rest]
  end

  defp append_to_batches(acc, block, true) do
    [{:concurrent, [block]} | acc]
  end

  defp append_to_batches(acc, block, false) do
    [{:serial, [block]} | acc]
  end
end
