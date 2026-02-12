defmodule Synapsis.Tool.Executor do
  @moduledoc "Executes tools with timeout and error handling."
  require Logger

  @default_timeout 30_000

  def execute(tool_name, input, context) do
    case Synapsis.Tool.Registry.get(tool_name) do
      {:ok, tool} ->
        timeout = tool[:timeout] || @default_timeout

        try do
          task =
            Task.Supervisor.async_nolink(Synapsis.Tool.TaskSupervisor, fn ->
              tool.module.call(input, context)
            end)

          case Task.yield(task, timeout) || Task.shutdown(task) do
            {:ok, {:ok, result}} -> {:ok, result}
            {:ok, {:error, reason}} -> {:error, reason}
            nil -> {:error, :timeout}
            {:exit, reason} -> {:error, {:exit, reason}}
          end
        rescue
          e -> {:error, Exception.message(e)}
        end

      {:error, :not_found} ->
        {:error, "Unknown tool: #{tool_name}"}
    end
  end
end
