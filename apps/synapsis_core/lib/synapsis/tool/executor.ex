defmodule Synapsis.Tool.Executor do
  @moduledoc "Executes tools with timeout, error handling, and side effect broadcasting."
  require Logger

  @default_timeout 30_000
  @default_safe_retries 2
  @default_unsafe_retries 0
  @default_retry_backoff 250
  @retryable_permission_levels [:none, :read]

  @type execute_result :: {:ok, term()} | {:error, term()}
  @type tool_call :: %{id: String.t(), name: String.t(), input: map()}

  # --- Public API ---

  @doc "Execute a tool call given as a map with :name and :input keys."
  def execute(%{name: name, input: input} = _tool_call, context) do
    execute(name, input, context)
  end

  @doc "Return the maximum expected runtime for one tool call including retries."
  def execution_budget_ms(context, opts \\ []) do
    timeout = resolve_timeout(opts, context)
    max_retries = max_retries_from_opts(opts, context, @default_safe_retries)
    backoff = retry_backoff_ms(opts, context)

    timeout * (max_retries + 1) + backoff * max_retries
  end

  @doc "Execute a tool by name with input and context."
  def execute(tool_name, input, context) when is_binary(tool_name) do
    with {:ok, entry} <- registry_lookup(tool_name),
         :ok <- check_enabled(entry),
         :ok <- check_permission(tool_name, context) do
      dispatch_with_retries(tool_name, entry, input, context)
    end
  end

  @doc "Execute a tool, skipping the permission check."
  def execute_approved(%{name: name, input: input}, context) do
    execute_approved(name, input, context)
  end

  def execute_approved(tool_name, input, context) when is_binary(tool_name) do
    with {:ok, entry} <- registry_lookup(tool_name),
         :ok <- check_enabled(entry) do
      dispatch_with_retries(tool_name, entry, input, context)
    end
  end

  @doc """
  Execute multiple tool calls concurrently, serializing calls that target the same file.

  Returns `[{call_id, result}]` in the original input order.
  """
  @spec execute_batch([tool_call()], map()) :: [{String.t(), execute_result()}]
  def execute_batch(tool_calls, context) when is_list(tool_calls) do
    # Build an order index so we can restore original ordering at the end
    indexed = Enum.with_index(tool_calls)

    # Group by file path — calls sharing a path are serialized
    groups =
      indexed
      |> Enum.group_by(fn {call, _idx} -> extract_file_path(call.input) end)

    # Each group becomes one unit of work.
    # Groups keyed by nil (no file path) can each run independently,
    # so we split them into individual items.
    work_units =
      Enum.flat_map(groups, fn
        {nil, items} ->
          Enum.map(items, fn item -> [item] end)

        {_path, items} ->
          [items]
      end)

    max_concurrency = System.schedulers_online()
    stream_timeout = batch_stream_timeout_ms(work_units, context)

    # Zip work units with their items so we can recover call IDs on crash
    results =
      work_units
      |> Task.async_stream(
        fn items ->
          Enum.map(items, fn {call, idx} ->
            result = execute(call.name, call.input, context)
            {call.id, result, idx}
          end)
        end,
        max_concurrency: max_concurrency,
        ordered: false,
        timeout: stream_timeout,
        on_timeout: :kill_task
      )
      |> Enum.zip(work_units)
      |> Enum.flat_map(fn
        {{:ok, results}, _items} ->
          results

        {{:exit, reason}, items} ->
          Logger.warning("tool_batch_task_crashed", reason: inspect(reason))

          Enum.map(items, fn {call, idx} ->
            {call.id, {:error, {:exit, reason}}, idx}
          end)
      end)
      |> Enum.sort_by(fn {_id, _result, idx} -> idx end)
      |> Enum.map(fn {id, result, _idx} -> {id, result} end)

    results
  end

  # --- Internal pipeline ---

  defp registry_lookup(tool_name) do
    case Synapsis.Tool.Registry.lookup(tool_name) do
      {:ok, _entry} = ok -> ok
      {:error, :not_found} -> {:error, "Unknown tool: #{tool_name}"}
    end
  end

  defp check_enabled({:module, module, _opts}) do
    if function_exported?(module, :enabled?, 0) and not module.enabled?() do
      {:error, :tool_disabled}
    else
      :ok
    end
  end

  defp check_enabled({:process, _pid, _opts}), do: :ok

  defp check_permission(tool_name, context) do
    session = context[:session] || context[:session_id]

    if session do
      case Synapsis.Tool.Permission.check(tool_name, session) do
        :approved -> :ok
        :denied -> {:error, :denied}
        :requires_approval -> {:error, :requires_approval}
      end
    else
      :ok
    end
  end

  defp dispatch(tool_name, {:module, module, opts}, input, context) do
    execute_module(tool_name, module, opts, input, context)
  end

  defp dispatch(tool_name, {:process, pid, opts}, input, context) do
    execute_process(tool_name, pid, opts, input, context)
  end

  defp dispatch_with_retries(tool_name, entry, input, context) do
    max_retries = max_retries_for_entry(entry, context)
    attempt_dispatch(tool_name, entry, input, context, 0, max_retries)
  end

  defp attempt_dispatch(tool_name, entry, input, context, attempt, max_retries) do
    case dispatch(tool_name, entry, input, context) do
      {:error, reason} = error ->
        if attempt < max_retries and retryable_reason?(reason) do
          Logger.warning("tool_call_retry",
            tool_name: tool_name,
            attempt: attempt + 1,
            max_retries: max_retries,
            reason: inspect(reason)
          )

          sleep_before_retry(entry, context, attempt)
          attempt_dispatch(tool_name, entry, input, context, attempt + 1, max_retries)
        else
          error
        end

      result ->
        result
    end
  end

  defp execute_module(tool_name, module, opts, input, context) do
    timeout = resolve_timeout(opts, context)
    start_time = System.monotonic_time(:millisecond)

    try do
      task =
        Task.Supervisor.async_nolink(Synapsis.Tool.TaskSupervisor, fn ->
          safe_module_execute(module, input, context)
        end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, result}} ->
          duration_ms = System.monotonic_time(:millisecond) - start_time
          persist_tool_call(tool_name, input, {:ok, result}, :completed, duration_ms, context)
          broadcast_side_effects(tool_name, module, context)
          {:ok, result}

        {:ok, {:error, reason}} ->
          duration_ms = System.monotonic_time(:millisecond) - start_time
          persist_tool_call(tool_name, input, {:error, reason}, :error, duration_ms, context)
          {:error, reason}

        nil ->
          duration_ms = System.monotonic_time(:millisecond) - start_time
          persist_tool_call(tool_name, input, {:error, :timeout}, :error, duration_ms, context)
          {:error, :timeout}

        {:exit, reason} ->
          duration_ms = System.monotonic_time(:millisecond) - start_time

          persist_tool_call(
            tool_name,
            input,
            {:error, {:exit, reason}},
            :error,
            duration_ms,
            context
          )

          {:error, {:exit, reason}}
      end
    rescue
      e in [RuntimeError, ArgumentError, FunctionClauseError] ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        msg = Exception.message(e)
        persist_tool_call(tool_name, input, {:error, msg}, :error, duration_ms, context)
        {:error, msg}
    end
  end

  defp safe_module_execute(module, input, context) do
    module.execute(input, context)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
    kind, reason -> {:error, {kind, reason}}
  end

  defp execute_process(tool_name, pid, opts, input, context) do
    timeout = resolve_timeout(opts, context)
    start_time = System.monotonic_time(:millisecond)

    try do
      result = GenServer.call(pid, {:execute, tool_name, input, context}, timeout)
      duration_ms = System.monotonic_time(:millisecond) - start_time
      status = if match?({:ok, _}, result), do: :completed, else: :error
      persist_tool_call(tool_name, input, result, status, duration_ms, context)
      result
    catch
      :exit, {:timeout, _} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        persist_tool_call(tool_name, input, {:error, :timeout}, :error, duration_ms, context)
        {:error, :timeout}

      :exit, reason ->
        duration_ms = System.monotonic_time(:millisecond) - start_time

        persist_tool_call(
          tool_name,
          input,
          {:error, {:exit, reason}},
          :error,
          duration_ms,
          context
        )

        {:error, {:exit, reason}}
    end
  end

  defp batch_stream_timeout_ms([], _context), do: @default_timeout

  defp batch_stream_timeout_ms(work_units, context) do
    work_units
    |> Enum.map(fn items ->
      items
      |> Enum.map(fn {call, _idx} -> tool_execution_budget_ms(call.name, context) end)
      |> Enum.sum()
    end)
    |> Enum.max(fn -> @default_timeout end)
    |> Kernel.+(1_000)
  end

  defp tool_execution_budget_ms(tool_name, context) do
    case registry_lookup(tool_name) do
      {:ok, entry} -> execution_budget_ms(context, entry_opts(entry))
      {:error, _reason} -> execution_budget_ms(context)
    end
  end

  defp resolve_timeout(opts, context) do
    context_value(context, :tool_timeout_ms)
    |> non_negative_integer(opts[:timeout] || @default_timeout)
  end

  defp max_retries_for_entry(entry, context) do
    default =
      if retry_safe_entry?(entry, context) do
        @default_safe_retries
      else
        @default_unsafe_retries
      end

    entry
    |> entry_opts()
    |> max_retries_from_opts(context, default)
  end

  defp max_retries_from_opts(opts, context, default) do
    value =
      context_value(context, :tool_max_retries) ||
        opts[:max_retries] ||
        opts[:retries]

    non_negative_integer(value, default)
  end

  defp retry_backoff_ms(opts, context) do
    value =
      context_value(context, :tool_retry_backoff_ms) ||
        opts[:retry_backoff_ms]

    non_negative_integer(value, @default_retry_backoff)
  end

  defp sleep_before_retry(entry, context, attempt) do
    entry
    |> entry_opts()
    |> retry_backoff_ms(context)
    |> Kernel.*(attempt + 1)
    |> Process.sleep()
  end

  defp retry_safe_entry?(entry, context) do
    context_value(context, :tool_retry_unsafe) == true or
      permission_level(entry) in @retryable_permission_levels
  end

  defp retryable_reason?(:timeout), do: true
  defp retryable_reason?({:timeout, _reason}), do: true
  defp retryable_reason?({:exit, :timeout}), do: true
  defp retryable_reason?({:exit, {:timeout, _reason}}), do: true

  defp retryable_reason?(reason) when is_binary(reason) do
    reason
    |> String.downcase()
    |> then(fn text ->
      String.contains?(text, "timeout") or
        String.contains?(text, "timed out") or
        String.contains?(text, "connection closed")
    end)
  end

  defp retryable_reason?(_reason), do: false

  defp permission_level({:module, module, opts}) do
    opts[:permission_level] ||
      (function_exported?(module, :permission_level, 0) && module.permission_level()) ||
      :write
  end

  defp permission_level({:process, _pid, opts}) do
    Keyword.get(opts, :permission_level, :read)
  end

  defp entry_opts({:module, _module, opts}), do: opts
  defp entry_opts({:process, _pid, opts}), do: opts

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

  defp broadcast_side_effects(_tool_name, module, context) do
    effects =
      if function_exported?(module, :side_effects, 0) do
        module.side_effects()
      else
        []
      end

    session_id = context[:session_id]

    if effects != [] and session_id do
      for effect <- effects do
        payload = {:tool_effect, effect, %{session_id: session_id}}

        Phoenix.PubSub.broadcast(
          Synapsis.PubSub,
          "tool_effects:#{session_id}",
          payload
        )

        Phoenix.PubSub.broadcast(
          Synapsis.PubSub,
          "tool_effects:global",
          payload
        )
      end
    end
  end

  # --- Persistence ---
  #
  # ADR-006 C4: tool invocations are captured in the session's Concord turns
  # (tool_use / tool_result parts), so there is no separate ToolCall table to
  # persist to. Retained as a no-op seam for future telemetry/audit.
  defp persist_tool_call(_tool_name, _input, _result, _status, _duration_ms, _context), do: :ok

  # --- Batch helpers ---

  defp extract_file_path(input) when is_map(input) do
    input["path"] || input["file_path"] || input["source"]
  end

  defp extract_file_path(_), do: nil
end
