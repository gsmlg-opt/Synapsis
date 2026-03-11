defmodule Synapsis.Tool.Executor do
  @moduledoc "Executes tools with timeout, error handling, and side effect broadcasting."
  require Logger

  @default_timeout 30_000

  @type execute_result :: {:ok, term()} | {:error, term()}
  @type tool_call :: %{id: String.t(), name: String.t(), input: map()}

  # --- Public API ---

  @doc "Execute a tool call given as a map with :name and :input keys."
  def execute(%{name: name, input: input} = _tool_call, context) do
    execute(name, input, context)
  end

  @doc "Execute a tool by name with input and context."
  def execute(tool_name, input, context) when is_binary(tool_name) do
    with {:ok, entry} <- registry_lookup(tool_name),
         :ok <- check_enabled(entry),
         :ok <- check_permission(tool_name, context) do
      dispatch(tool_name, entry, input, context)
    end
  end

  @doc "Execute a tool, skipping the permission check."
  def execute_approved(%{name: name, input: input}, context) do
    execute_approved(name, input, context)
  end

  def execute_approved(tool_name, input, context) when is_binary(tool_name) do
    with {:ok, entry} <- registry_lookup(tool_name),
         :ok <- check_enabled(entry) do
      dispatch(tool_name, entry, input, context)
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
        timeout: :infinity,
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

  defp execute_module(tool_name, module, opts, input, context) do
    timeout = opts[:timeout] || @default_timeout
    start_time = System.monotonic_time(:millisecond)

    try do
      task =
        Task.Supervisor.async_nolink(Synapsis.Tool.TaskSupervisor, fn ->
          module.execute(input, context)
        end)

      case Task.yield(task, timeout) || Task.shutdown(task) do
        {:ok, {:ok, result}} ->
          duration_ms = System.monotonic_time(:millisecond) - start_time
          broadcast_side_effects(tool_name, module, context)
          persist_tool_call(tool_name, input, {:ok, result}, :completed, duration_ms, context)
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
      e ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        msg = Exception.message(e)
        persist_tool_call(tool_name, input, {:error, msg}, :error, duration_ms, context)
        {:error, msg}
    end
  end

  defp execute_process(tool_name, pid, opts, input, context) do
    timeout = opts[:timeout] || @default_timeout
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
        Phoenix.PubSub.broadcast(
          Synapsis.PubSub,
          "tool_effects:#{session_id}",
          {:tool_effect, effect, %{session_id: session_id}}
        )
      end
    end
  end

  # --- Persistence (T029) ---

  defp persist_tool_call(tool_name, input, result, status, duration_ms, context) do
    session_id = context[:session_id]

    if session_id do
      try do
        {output, error_message} = encode_result(result)

        attrs = %{
          session_id: session_id,
          tool_name: tool_name,
          input: input,
          output: output,
          status: status,
          duration_ms: duration_ms,
          error_message: error_message
        }

        # Include message_id if present in context
        attrs =
          if context[:message_id] do
            Map.put(attrs, :message_id, context[:message_id])
          else
            attrs
          end

        %Synapsis.ToolCall{}
        |> Synapsis.ToolCall.changeset(attrs)
        |> Synapsis.Repo.insert()
      rescue
        e ->
          Logger.warning("tool_call_persist_failed",
            tool_name: tool_name,
            error: Exception.message(e)
          )

          :ok
      end
    end
  end

  defp encode_result({:ok, result}) when is_map(result), do: {result, nil}
  defp encode_result({:ok, result}) when is_binary(result), do: {%{"result" => result}, nil}
  defp encode_result({:ok, result}), do: {%{"result" => inspect(result)}, nil}
  defp encode_result({:error, reason}) when is_binary(reason), do: {nil, reason}
  defp encode_result({:error, reason}), do: {nil, inspect(reason)}

  # --- Batch helpers ---

  defp extract_file_path(input) when is_map(input) do
    input["path"] || input["file_path"] || input["source"]
  end

  defp extract_file_path(_), do: nil
end
