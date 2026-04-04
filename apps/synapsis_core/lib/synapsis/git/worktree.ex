defmodule Synapsis.Git.Worktree do
  @moduledoc "Git worktree management: create, remove, list, prune."

  alias Synapsis.Git.Runner

  @doc """
  Creates a worktree at `worktree_path` checked out on `branch`.

  Creates parent directories as needed.
  """
  @spec create(String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def create(bare_path, worktree_path, branch) do
    File.mkdir_p!(Path.dirname(worktree_path))

    case Runner.run(bare_path, ["worktree", "add", worktree_path, branch]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Removes a worktree by path (force-removes even with uncommitted changes).
  """
  @spec remove(String.t(), String.t()) :: :ok | {:error, String.t()}
  def remove(bare_path, worktree_path) do
    case Runner.run(bare_path, ["worktree", "remove", worktree_path, "--force"]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Lists all worktrees for the repository.

  Returns `{:ok, [%{path: path, branch: branch, head: sha}]}`.
  """
  @spec list(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def list(bare_path) do
    case Runner.run(bare_path, ["worktree", "list", "--porcelain"]) do
      {:ok, output} -> {:ok, parse_worktree_list(output)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Prunes stale worktree administrative files.
  """
  @spec prune(String.t()) :: :ok | {:error, String.t()}
  def prune(bare_path) do
    case Runner.run(bare_path, ["worktree", "prune"]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  # -- Private --

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
      %{path: _} = e -> e
      _ -> nil
    end
  end
end
