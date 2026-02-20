defmodule Synapsis.GitWorktree do
  @moduledoc """
  Git worktree management for isolated agent workspaces.

  Provides Port-based git worktree operations for creating isolated
  working directories where agents can make changes without affecting
  the main checkout. Follows the same execution pattern as `Synapsis.Git`.
  """

  @default_timeout 30_000

  @doc """
  Creates a new git worktree at the given path on a new branch.

  Creates the branch automatically. If the branch already exists,
  uses `git worktree add` without `-b`.
  """
  @spec add(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def add(project_path, worktree_path, branch) do
    case run(project_path, ["worktree", "add", "-b", branch, worktree_path]) do
      {:ok, _} = ok ->
        ok

      {:error, msg} ->
        if String.contains?(msg, "already exists") do
          run(project_path, ["worktree", "add", worktree_path, branch])
        else
          {:error, msg}
        end
    end
  end

  @doc """
  Removes a git worktree and prunes stale entries.
  """
  @spec remove(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def remove(project_path, worktree_path) do
    with {:ok, _} <- run(project_path, ["worktree", "remove", worktree_path, "--force"]),
         {:ok, _} = result <- run(project_path, ["worktree", "prune"]) do
      result
    end
  end

  @doc """
  Lists active worktrees for the given project.

  Returns a list of `%{path: path, branch: branch, head: commit_sha}` maps.
  """
  @spec list(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def list(project_path) do
    case run(project_path, ["worktree", "list", "--porcelain"]) do
      {:ok, output} -> {:ok, parse_worktree_list(output)}
      error -> error
    end
  end

  @doc """
  Applies a unified diff patch in the given worktree directory.

  Uses `git apply` with `--allow-empty` to handle edge cases.
  """
  @spec apply_patch(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def apply_patch(worktree_path, patch_text) do
    # Write patch to a temp file, then apply it — avoids stdin pipe issues with Port
    tmp_path = Path.join(System.tmp_dir!(), "synapsis_patch_#{System.unique_integer([:positive])}.patch")

    try do
      File.write!(tmp_path, patch_text)
      run(worktree_path, ["apply", "--verbose", tmp_path])
    after
      File.rm(tmp_path)
    end
  rescue
    e -> {:error, "git apply error: #{Exception.message(e)}"}
  end

  @doc """
  Checks if a path is inside a git worktree (not the main working tree).
  """
  @spec is_worktree?(String.t()) :: boolean()
  def is_worktree?(path) do
    case run(path, ["rev-parse", "--git-common-dir"]) do
      {:ok, common_dir} ->
        case run(path, ["rev-parse", "--git-dir"]) do
          {:ok, git_dir} ->
            String.trim(common_dir) != String.trim(git_dir)

          _ ->
            false
        end

      _ ->
        false
    end
  end

  # -- Private --

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

  defp parse_worktree_list(output) do
    output
    |> String.split("\n\n", trim: true)
    |> Enum.map(&parse_worktree_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_worktree_entry(entry) do
    lines = String.split(entry, "\n", trim: true)

    Enum.reduce(lines, %{}, fn line, acc ->
      case String.split(line, " ", parts: 2) do
        ["worktree", path] -> Map.put(acc, :path, path)
        ["HEAD", sha] -> Map.put(acc, :head, sha)
        ["branch", ref] -> Map.put(acc, :branch, String.replace_prefix(ref, "refs/heads/", ""))
        ["detached"] -> Map.put(acc, :branch, "(detached)")
        ["bare"] -> Map.put(acc, :bare, true)
        _ -> acc
      end
    end)
    |> case do
      %{path: _} = entry -> entry
      _ -> nil
    end
  end
end
