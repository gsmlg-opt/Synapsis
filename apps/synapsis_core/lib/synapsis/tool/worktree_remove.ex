defmodule Synapsis.Tool.WorktreeRemove do
  @moduledoc "Remove a git worktree and optionally delete its branch."
  use Synapsis.Tool

  @impl true
  def name, do: "worktree_remove"

  @impl true
  def description,
    do:
      "Remove a git worktree. Refuses to remove active worktrees unless force is true. " <>
        "Optionally deletes the branch after removal."

  @impl true
  def permission_level, do: :none

  @impl true
  def category, do: :workflow

  @impl true
  def side_effects, do: [:worktree_removed]

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "worktree_id" => %{
          "type" => "string",
          "description" => "The worktree ID to remove"
        },
        "delete_branch" => %{
          "type" => "boolean",
          "description" => "Also delete the branch after removing the worktree (default false)"
        },
        "force" => %{
          "type" => "boolean",
          "description" => "Force remove even if the worktree is active (default false)"
        }
      },
      "required" => ["worktree_id"]
    }
  end

  @impl true
  def execute(input, _context) do
    worktree_id = Map.get(input, "worktree_id")
    delete_branch = Map.get(input, "delete_branch", false)
    force = Map.get(input, "force", false)

    case Synapsis.Worktrees.get(worktree_id) do
      nil ->
        {:error, "Worktree #{worktree_id} not found"}

      worktree ->
        if worktree.status == :active and not force do
          {:error, "Worktree is active — set force: true to remove it anyway"}
        else
          repo = Synapsis.Repos.get(worktree.repo_id)

          if is_nil(repo) do
            {:error, "Repository for worktree not found"}
          else
            with :ok <- Synapsis.Git.Worktree.remove(repo.bare_path, worktree.local_path),
                 {:ok, _} <- update_worktree_status(worktree, force),
                 :ok <- maybe_delete_branch(repo.bare_path, worktree.branch, delete_branch) do
              {:ok,
               Jason.encode!(%{
                 worktree_id: worktree.id,
                 branch: worktree.branch,
                 status: "removed"
               })}
            end
          end
        end
    end
  end

  defp update_worktree_status(%{status: :active} = worktree, true) do
    Synapsis.Worktrees.mark_failed(worktree)
  end

  defp update_worktree_status(worktree, _force) do
    case worktree.status do
      :completed -> {:ok, worktree}
      :failed -> {:ok, worktree}
      _ -> Synapsis.Worktrees.mark_failed(worktree)
    end
  end

  defp maybe_delete_branch(_bare_path, _branch, false), do: :ok

  defp maybe_delete_branch(bare_path, branch, true) do
    case Synapsis.Git.Branch.delete(bare_path, branch, true) do
      :ok -> :ok
      {:error, reason} -> {:error, "Branch delete failed: #{reason}"}
    end
  end
end
