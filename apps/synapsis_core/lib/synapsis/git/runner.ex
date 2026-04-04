defmodule Synapsis.Git.Runner do
  @moduledoc "Shared Port-based git command execution."

  @default_timeout 30_000

  @doc """
  Runs a git command in the given working directory.

  Returns `{:ok, stdout}` on exit code 0, or `{:error, message}` on failure or timeout.
  """
  @spec run(String.t(), [String.t()], keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(cwd, args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case System.find_executable("git") do
      nil ->
        {:error, "git executable not found"}

      git_path ->
        port =
          Port.open({:spawn_executable, git_path}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: args,
            cd: cwd
          ])

        collect_output(port, "", timeout)
    end
  rescue
    e in [RuntimeError, ArgumentError, ErlangError] ->
      {:error, "git error: #{Exception.message(e)}"}
  end

  defp collect_output(port, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, acc <> data, timeout)

      {^port, {:exit_status, 0}} ->
        {:ok, acc}

      {^port, {:exit_status, code}} ->
        {:error, "git exited with #{code}: #{acc}"}
    after
      timeout ->
        Port.close(port)
        {:error, "git command timed out after #{timeout}ms"}
    end
  end
end
