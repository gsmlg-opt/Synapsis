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

  @type tool_result :: %{
          tool_use_id: String.t(),
          content: String.t(),
          is_error: boolean()
        }

  @doc """
  Execute tool blocks with concurrency partitioning.
  Returns tool_result maps in the original block order.
  """
  @spec run([tool_block()], map(), map()) :: [tool_result()]
  def run(blocks, tool_map, context) do
    batches = partition(blocks, tool_map)

    Enum.flat_map(batches, fn
      {:concurrent, items} ->
        items
        |> Task.async_stream(
          fn block -> {block.id, run_one(block, tool_map, context)} end,
          max_concurrency: System.schedulers_online(),
          ordered: true,
          timeout: 60_000,
          on_timeout: :kill_task
        )
        |> Enum.map(fn
          {:ok, {id, result}} -> format_result(id, result)
          {:exit, {id, _reason}} -> %{tool_use_id: id, content: "Tool execution timed out", is_error: true}
        end)

      {:serial, items} ->
        Enum.map(items, fn block ->
          result = run_one(block, tool_map, context)
          format_result(block.id, result)
        end)
    end)
  end

  @doc "Execute a single tool call."
  @spec run_one(tool_block(), map(), map()) :: {:ok, term()} | {:error, term()}
  def run_one(%{name: name, input: input}, tool_map, context) do
    case Map.get(tool_map, name) do
      nil ->
        {:error, "Unknown tool: #{name}"}

      mod ->
        try do
          mod.execute(input, context)
        rescue
          e -> {:error, Exception.message(e)}
        catch
          :exit, reason -> {:error, "Tool exited: #{inspect(reason)}"}
        end
    end
  end

  defp format_result(id, {:ok, result}) when is_binary(result) do
    %{tool_use_id: id, content: result, is_error: false}
  end

  defp format_result(id, {:ok, result}) do
    %{tool_use_id: id, content: inspect(result), is_error: false}
  end

  defp format_result(id, {:error, reason}) when is_binary(reason) do
    %{tool_use_id: id, content: reason, is_error: true}
  end

  defp format_result(id, {:error, reason}) do
    %{tool_use_id: id, content: inspect(reason), is_error: true}
  end
end
