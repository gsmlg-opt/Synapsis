defmodule Synapsis.Git do
  @moduledoc "Git integration for auto-checkpointing and undo."

  @default_timeout 10_000

  def checkpoint(project_path, message \\ "synapsis auto-checkpoint") do
    with {:ok, _} <- run(project_path, ["add", "-A"]),
         {:ok, status} <- run(project_path, ["status", "--porcelain"]) do
      if String.trim(status) != "" do
        run(project_path, ["commit", "-m", message, "--no-verify"])
      else
        {:ok, "nothing to commit"}
      end
    end
  end

  def undo_last(project_path) do
    case last_commit_message(project_path) do
      {:ok, msg} ->
        if String.starts_with?(msg, "synapsis ") do
          run(project_path, ["reset", "--soft", "HEAD~1"])
        else
          {:error, "last commit is not a synapsis checkpoint"}
        end

      error ->
        error
    end
  end

  def last_commit_message(project_path) do
    case run(project_path, ["log", "-1", "--format=%s"]) do
      {:ok, msg} -> {:ok, String.trim(msg)}
      error -> error
    end
  end

  def diff(project_path, opts \\ []) do
    args = ["diff"] ++ Keyword.get(opts, :args, [])
    run(project_path, args)
  end

  def is_repo?(project_path) do
    case run(project_path, ["rev-parse", "--is-inside-work-tree"]) do
      {:ok, "true" <> _} -> true
      _ -> false
    end
  end

  defp run(project_path, args) do
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
            cd: project_path
          ])

        collect_output(port, "")
    end
  rescue
    e -> {:error, "git error: #{Exception.message(e)}"}
  end

  defp collect_output(port, acc) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, acc <> data)

      {^port, {:exit_status, 0}} ->
        {:ok, acc}

      {^port, {:exit_status, code}} ->
        {:error, "git exited with #{code}: #{acc}"}
    after
      @default_timeout ->
        Port.close(port)
        {:error, "git command timed out after #{@default_timeout}ms"}
    end
  end
end
