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
  @default_timeout_ms 30_000
  @default_safe_retries 2
  @default_unsafe_retries 0
  @default_retry_backoff_ms 250

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

      tool_spec ->
        permission_level(tool_spec) in @concurrent_permission_levels
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
          fn block -> run_one(block, tool_map, context) end,
          max_concurrency: System.schedulers_online(),
          ordered: true,
          timeout: stream_timeout_ms(items, tool_map, context),
          on_timeout: :kill_task
        )
        |> Enum.zip(items)
        |> Enum.map(fn
          {{:ok, result}, block} ->
            format_result(block.id, result)

          {{:exit, :timeout}, block} ->
            %{tool_use_id: block.id, content: "Tool execution timed out", is_error: true}

          {{:exit, reason}, block} ->
            %{
              tool_use_id: block.id,
              content: "Tool execution failed: #{inspect(reason)}",
              is_error: true
            }
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

      {:module, _module, _opts} ->
        Synapsis.Tool.Executor.execute_approved(name, input, context)

      {:process, _pid, _opts} ->
        Synapsis.Tool.Executor.execute_approved(name, input, context)

      mod when is_atom(mod) ->
        execute_module_with_retries(name, mod, input, context)
    end
  end

  defp execute_module_with_retries(name, mod, input, context) do
    max_retries = max_retries_for_module(mod, context)
    attempt_module(name, mod, input, context, 0, max_retries)
  end

  defp attempt_module(name, mod, input, context, attempt, max_retries) do
    case execute_module_once(mod, input, context) do
      {:error, reason} = error ->
        if attempt < max_retries and retryable_reason?(reason) do
          Logger.warning("query_loop_tool_retry",
            tool_name: name,
            attempt: attempt + 1,
            max_retries: max_retries,
            reason: inspect(reason)
          )

          Process.sleep(retry_backoff_ms(context) * (attempt + 1))
          attempt_module(name, mod, input, context, attempt + 1, max_retries)
        else
          error
        end

      result ->
        result
    end
  end

  defp execute_module_once(mod, input, context) do
    timeout = timeout_ms(context)

    try do
      task =
        Task.Supervisor.async_nolink(Synapsis.Tool.TaskSupervisor, fn ->
          safe_module_execute(mod, input, context)
        end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, _result} = ok} -> ok
        {:ok, {:error, _reason} = error} -> error
        {:ok, result} -> {:ok, result}
        {:exit, reason} -> {:error, {:exit, reason}}
        nil -> {:error, :timeout}
      end
    rescue
      e -> {:error, Exception.message(e)}
    catch
      :exit, reason -> {:error, {:exit, reason}}
    end
  end

  defp safe_module_execute(mod, input, context) do
    mod.execute(input, context)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
    kind, reason -> {:error, {kind, reason}}
  end

  defp stream_timeout_ms(items, tool_map, context) do
    items
    |> Enum.map(fn block ->
      tool_map
      |> Map.get(block.name)
      |> execution_budget_ms(context)
    end)
    |> Enum.max(fn -> @default_timeout_ms end)
    |> Kernel.+(1_000)
  end

  defp execution_budget_ms({:module, _module, opts}, context) do
    Synapsis.Tool.Executor.execution_budget_ms(context, opts)
  end

  defp execution_budget_ms({:process, _pid, opts}, context) do
    Synapsis.Tool.Executor.execution_budget_ms(context, opts)
  end

  defp execution_budget_ms(mod, context) when is_atom(mod) do
    timeout = timeout_ms(context)
    max_retries = max_retries_for_module(mod, context)
    backoff = retry_backoff_ms(context)

    timeout * (max_retries + 1) + backoff * max_retries
  end

  defp execution_budget_ms(_tool_spec, _context), do: @default_timeout_ms

  defp max_retries_for_module(mod, context) do
    default =
      if retry_safe_module?(mod, context) do
        @default_safe_retries
      else
        @default_unsafe_retries
      end

    context
    |> context_value(:tool_max_retries)
    |> non_negative_integer(default)
  end

  defp retry_safe_module?(mod, context) do
    context_value(context, :tool_retry_unsafe) == true or
      permission_level(mod) in @concurrent_permission_levels
  end

  defp retryable_reason?(:timeout), do: true
  defp retryable_reason?({:exit, :timeout}), do: true
  defp retryable_reason?({:exit, {:timeout, _reason}}), do: true
  defp retryable_reason?(_reason), do: false

  defp timeout_ms(context) do
    context
    |> context_value(:tool_timeout_ms)
    |> non_negative_integer(@default_timeout_ms)
  end

  defp retry_backoff_ms(context) do
    context
    |> context_value(:tool_retry_backoff_ms)
    |> non_negative_integer(@default_retry_backoff_ms)
  end

  defp permission_level({:module, module, opts}) do
    opts[:permission_level] ||
      (function_exported?(module, :permission_level, 0) && module.permission_level()) ||
      :write
  end

  defp permission_level({:process, _pid, opts}) do
    Keyword.get(opts, :permission_level, :read)
  end

  defp permission_level(mod) when is_atom(mod) do
    if function_exported?(mod, :permission_level, 0),
      do: mod.permission_level(),
      else: :write
  end

  defp context_value(context, key) do
    Map.get(context, key) || Map.get(context, to_string(key))
  end

  defp non_negative_integer(value, _default) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> int
      _ -> default
    end
  end

  defp non_negative_integer(_value, default), do: default

  defp format_result(id, {:ok, result}) when is_binary(result) do
    %{tool_use_id: id, content: result, is_error: false}
  end

  defp format_result(id, {:ok, result}) do
    %{tool_use_id: id, content: inspect(result), is_error: false}
  end

  defp format_result(id, {:error, reason}) when is_binary(reason) do
    %{tool_use_id: id, content: reason, is_error: true}
  end

  defp format_result(id, {:error, :timeout}) do
    %{tool_use_id: id, content: "Tool execution timed out", is_error: true}
  end

  defp format_result(id, {:error, reason}) do
    %{tool_use_id: id, content: inspect(reason), is_error: true}
  end
end
