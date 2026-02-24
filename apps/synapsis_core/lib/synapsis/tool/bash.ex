defmodule Synapsis.Tool.Bash do
  @moduledoc "Execute shell commands via Port (not System.cmd)."
  use Synapsis.Tool

  @default_timeout 30_000
  @max_timeout 300_000
  @max_output_bytes 10_000_000

  @impl true
  def name, do: "bash"

  @impl true
  def description, do: "Execute a shell command and return its output."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "command" => %{"type" => "string", "description" => "The shell command to execute"},
        "timeout" => %{
          "type" => "integer",
          "description" => "Timeout in milliseconds (default 30000)"
        }
      },
      "required" => ["command"]
    }
  end

  @impl true
  def execute(input, context) do
    command = input["command"]
    timeout = min(input["timeout"] || @default_timeout, @max_timeout)
    cwd = context[:project_path] || "."

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-c", command],
        cd: cwd
      ])

    deadline = System.monotonic_time(:millisecond) + timeout
    collect_output(port, "", deadline, timeout)
  end

  defp collect_output(port, acc, deadline, original_timeout) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Port.close(port)
      {:error, "Command timed out after #{original_timeout}ms\n#{acc}"}
    else
      receive do
        {^port, {:data, data}} ->
          new_acc = acc <> data

          if byte_size(new_acc) > @max_output_bytes do
            Port.close(port)
            {:ok, binary_part(new_acc, 0, @max_output_bytes) <> "\n[Output truncated at 10MB]"}
          else
            collect_output(port, new_acc, deadline, original_timeout)
          end

        {^port, {:exit_status, 0}} ->
          {:ok, String.trim_trailing(acc)}

        {^port, {:exit_status, status}} ->
          {:ok, "Exit code: #{status}\n#{String.trim_trailing(acc)}"}
      after
        remaining ->
          Port.close(port)
          {:error, "Command timed out after #{original_timeout}ms\n#{acc}"}
      end
    end
  end
end
