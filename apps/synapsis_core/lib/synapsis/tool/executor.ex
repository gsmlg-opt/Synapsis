defmodule Synapsis.Tool.Executor do
  @moduledoc "Executes tools with timeout, error handling, and side effect broadcasting."
  require Logger

  @default_timeout 30_000

  def execute(tool_name, input, context) do
    case Synapsis.Tool.Registry.lookup(tool_name) do
      {:ok, {:module, module, opts}} ->
        execute_module(tool_name, module, opts, input, context)

      {:ok, {:process, pid, opts}} ->
        execute_process(tool_name, pid, opts, input, context)

      {:error, :not_found} ->
        {:error, "Unknown tool: #{tool_name}"}
    end
  end

  defp execute_module(tool_name, module, opts, input, context) do
    timeout = opts[:timeout] || @default_timeout

    try do
      task =
        Task.Supervisor.async_nolink(Synapsis.Tool.TaskSupervisor, fn ->
          module.execute(input, context)
        end)

      case Task.yield(task, timeout) || Task.shutdown(task) do
        {:ok, {:ok, result}} ->
          broadcast_side_effects(tool_name, module, context)
          {:ok, result}

        {:ok, {:error, reason}} ->
          {:error, reason}

        nil ->
          {:error, :timeout}

        {:exit, reason} ->
          {:error, {:exit, reason}}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp execute_process(tool_name, pid, opts, input, context) do
    timeout = opts[:timeout] || @default_timeout

    try do
      GenServer.call(pid, {:execute, tool_name, input, context}, timeout)
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
      :exit, reason -> {:error, {:exit, reason}}
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
end
