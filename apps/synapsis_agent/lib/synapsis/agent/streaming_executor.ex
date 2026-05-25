defmodule Synapsis.Agent.StreamingExecutor do
  @moduledoc """
  Eagerly dispatches tool calls as they arrive during LLM streaming.

  Concurrent-safe tools start immediately. Serial tools queue until
  all prior tools complete. Results are always returned in submission order.
  """

  alias Synapsis.Agent.QueryLoop.Executor

  @concurrent_permission_levels [:none, :read]

  defmodule TrackedTool do
    @moduledoc false
    defstruct [
      :id,
      :name,
      :input,
      :status,
      :concurrent_safe?,
      :task_ref,
      :task_pid,
      :started_at_ms,
      :result,
      :order
    ]

    # status: :queued | :executing | :completed
  end

  @type t :: %__MODULE__{
          tools: [TrackedTool.t()],
          tool_map: map(),
          context: map(),
          next_order: non_neg_integer()
        }

  defstruct tools: [],
            tool_map: %{},
            context: %{},
            next_order: 0

  @doc "Create a new StreamingExecutor."
  @spec new(map(), map()) :: t()
  def new(tool_map, context) do
    %__MODULE__{tool_map: tool_map, context: context}
  end

  @doc "Add a tool block for execution. Starts immediately if concurrent-safe."
  @spec add_tool(t(), map()) :: t()
  def add_tool(%__MODULE__{} = exec, %{id: id, name: name, input: input}) do
    safe? = concurrent_safe?(name, exec.tool_map)

    tracked = %TrackedTool{
      id: id,
      name: name,
      input: input,
      status: :queued,
      concurrent_safe?: safe?,
      order: exec.next_order
    }

    exec = %{exec | tools: exec.tools ++ [tracked], next_order: exec.next_order + 1}
    maybe_start_tools(exec)
  end

  @doc "Drain completed results (non-blocking). Returns {results_in_order, updated_exec}."
  @spec get_completed_results(t()) :: {[map()], t()}
  def get_completed_results(%__MODULE__{} = exec) do
    exec = check_completions(exec)

    {completed, remaining} = Enum.split_with(exec.tools, &(&1.status == :completed))

    results =
      completed
      |> Enum.sort_by(& &1.order)
      |> Enum.map(& &1.result)

    exec = %{exec | tools: remaining}
    exec = maybe_start_tools(exec)
    {results, exec}
  end

  @doc "Wait for ALL in-flight and queued tools. Returns {all_results_in_order, updated_exec}."
  @spec get_remaining_results(t()) :: {[map()], t()}
  def get_remaining_results(%__MODULE__{} = exec) do
    exec = start_all_queued(exec)
    exec = wait_all(exec)

    results =
      exec.tools
      |> Enum.sort_by(& &1.order)
      |> Enum.map(& &1.result)

    {results, %{exec | tools: []}}
  end

  # -- Private --

  defp concurrent_safe?(name, tool_map) do
    case Map.get(tool_map, name) do
      nil ->
        false

      tool_spec ->
        permission_level(tool_spec) in @concurrent_permission_levels
    end
  end

  defp maybe_start_tools(%__MODULE__{} = exec) do
    any_serial_executing? =
      Enum.any?(exec.tools, fn t ->
        t.status == :executing and not t.concurrent_safe?
      end)

    any_executing? = Enum.any?(exec.tools, &(&1.status == :executing))

    tools =
      Enum.map(exec.tools, fn
        %TrackedTool{status: :queued, concurrent_safe?: true} = t ->
          if any_serial_executing?, do: t, else: start_tool(t, exec)

        %TrackedTool{status: :queued, concurrent_safe?: false} = t ->
          if any_executing?, do: t, else: start_tool(t, exec)

        t ->
          t
      end)

    %{exec | tools: tools}
  end

  defp start_all_queued(%__MODULE__{} = exec) do
    tools =
      Enum.map(exec.tools, fn
        %TrackedTool{status: :queued} = t -> start_tool(t, exec)
        t -> t
      end)

    %{exec | tools: tools}
  end

  defp start_tool(%TrackedTool{} = t, exec) do
    parent = self()
    ref = make_ref()

    case Task.Supervisor.start_child(Synapsis.Tool.TaskSupervisor, fn ->
           result = Executor.run_one(%{name: t.name, input: t.input}, exec.tool_map, exec.context)
           send(parent, {:streaming_tool_done, ref, t.id, result})
         end) do
      {:ok, pid} ->
        %{
          t
          | status: :executing,
            task_ref: ref,
            task_pid: pid,
            started_at_ms: System.monotonic_time(:millisecond)
        }

      {:error, reason} ->
        %{
          t
          | status: :completed,
            result: %{
              tool_use_id: t.id,
              content: "Tool execution failed: #{inspect(reason)}",
              is_error: true
            }
        }
    end
  end

  defp check_completions(%__MODULE__{} = exec) do
    tools =
      Enum.map(exec.tools, fn
        %TrackedTool{status: :executing, task_ref: ref, id: id} = t ->
          receive do
            {:streaming_tool_done, ^ref, ^id, result} ->
              %{t | status: :completed, result: format_result(id, result)}
          after
            0 ->
              if tool_timed_out?(t, exec) do
                stop_tool_task(t)
                %{t | status: :completed, result: timeout_result(id)}
              else
                t
              end
          end

        t ->
          t
      end)

    %{exec | tools: tools}
  end

  defp wait_all(%__MODULE__{} = exec) do
    tools =
      Enum.map(exec.tools, fn
        %TrackedTool{status: :executing} = t ->
          wait_for_tool(t, exec)

        %TrackedTool{status: :completed} = t ->
          t

        %TrackedTool{status: :queued} = t ->
          # Shouldn't happen after start_all_queued, but handle gracefully
          started = start_tool(t, exec)
          wait_for_tool(started, exec)
      end)

    %{exec | tools: tools}
  end

  defp wait_for_tool(%TrackedTool{status: :completed} = t, _exec), do: t

  defp wait_for_tool(%TrackedTool{task_ref: ref, id: id} = t, exec) when not is_nil(ref) do
    receive do
      {:streaming_tool_done, ^ref, ^id, result} ->
        %{t | status: :completed, result: format_result(id, result)}
    after
      wait_timeout_ms(t, exec) ->
        stop_tool_task(t)
        %{t | status: :completed, result: timeout_result(id)}
    end
  end

  defp wait_for_tool(%TrackedTool{id: id} = t, _exec) do
    %{
      t
      | status: :completed,
        result: %{tool_use_id: id, content: "Tool execution failed to start", is_error: true}
    }
  end

  defp tool_timed_out?(%TrackedTool{started_at_ms: nil}, _exec), do: false

  defp tool_timed_out?(%TrackedTool{started_at_ms: started_at_ms} = t, exec) do
    System.monotonic_time(:millisecond) - started_at_ms >= wait_timeout_ms(t, exec)
  end

  defp wait_timeout_ms(%TrackedTool{name: name}, exec) do
    exec.tool_map
    |> Map.get(name)
    |> execution_budget_ms(exec.context)
    |> Kernel.+(1_000)
  end

  defp execution_budget_ms({:module, _module, opts}, context) do
    Synapsis.Tool.Executor.execution_budget_ms(context, opts)
  end

  defp execution_budget_ms({:process, _pid, opts}, context) do
    Synapsis.Tool.Executor.execution_budget_ms(context, opts)
  end

  defp execution_budget_ms(_tool_spec, context) do
    Synapsis.Tool.Executor.execution_budget_ms(context)
  end

  defp stop_tool_task(%TrackedTool{task_pid: pid}) when is_pid(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
  end

  defp stop_tool_task(_tool), do: :ok

  defp timeout_result(id) do
    %{tool_use_id: id, content: "Tool execution timed out", is_error: true}
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

  defp format_result(id, {:ok, result}) when is_binary(result),
    do: %{tool_use_id: id, content: result, is_error: false}

  defp format_result(id, {:ok, result}),
    do: %{tool_use_id: id, content: inspect(result), is_error: false}

  defp format_result(id, {:error, reason}) when is_binary(reason),
    do: %{tool_use_id: id, content: reason, is_error: true}

  defp format_result(id, {:error, :timeout}),
    do: timeout_result(id)

  defp format_result(id, {:error, reason}),
    do: %{tool_use_id: id, content: inspect(reason), is_error: true}
end
