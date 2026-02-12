defmodule Synapsis.Git do
  @moduledoc "Git integration for auto-checkpointing and undo."

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
    case System.cmd("git", args, cd: project_path, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, "git exited with #{code}: #{output}"}
    end
  rescue
    e -> {:error, "git error: #{Exception.message(e)}"}
  end
end
