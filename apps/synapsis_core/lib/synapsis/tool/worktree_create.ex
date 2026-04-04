defmodule Synapsis.Tool.WorktreeCreate do
  @moduledoc "Create a git worktree for agent-isolated development."
  use Synapsis.Tool

  @impl true
  def name, do: "worktree_create"

  @impl true
  def description,
    do:
      "Create a git worktree on a branch for an agent to work in isolation. " <>
        "Creates the branch if it does not exist. Returns worktree_id and local_path."

  @impl true
  def permission_level, do: :none

  @impl true
  def category, do: :workflow

  @impl true
  def side_effects, do: [:worktree_created]

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "repo_id" => %{
          "type" => "string",
          "description" => "The repository ID to create the worktree from"
        },
        "branch" => %{
          "type" => "string",
          "description" => "Branch name for the worktree"
        },
        "base_branch" => %{
          "type" => "string",
          "description" =>
            "Base branch to create the new branch from (defaults to default_branch)"
        },
        "task_id" => %{
          "type" => "string",
          "description" => "Optional task ID to associate with this worktree"
        }
      },
      "required" => ["repo_id", "branch"]
    }
  end

  @impl true
  def execute(input, _context) do
    repo_id = Map.get(input, "repo_id")
    branch = Map.get(input, "branch")
    task_id = Map.get(input, "task_id")

    case Synapsis.Repos.get(repo_id) do
      nil ->
        {:error, "Repository #{repo_id} not found"}

      repo ->
        base_branch = Map.get(input, "base_branch", repo.default_branch)

        with :ok <- ensure_branch(repo.bare_path, branch, base_branch),
             {:ok, worktree_path} <- compute_worktree_path(repo.bare_path, branch),
             :ok <- Synapsis.Git.Worktree.create(repo.bare_path, worktree_path, branch),
             {:ok, worktree} <-
               Synapsis.Worktrees.create(repo.id, %{
                 branch: branch,
                 base_branch: base_branch,
                 local_path: worktree_path,
                 task_id: task_id
               }) do
          {:ok,
           Jason.encode!(%{
             worktree_id: worktree.id,
             local_path: worktree_path,
             branch: branch,
             repo_id: repo.id
           })}
        end
    end
  end

  defp ensure_branch(bare_path, branch, base_branch) do
    if Synapsis.Git.Branch.exists?(bare_path, branch) do
      :ok
    else
      Synapsis.Git.Branch.create(bare_path, branch, base_branch)
    end
  end

  defp compute_worktree_path(bare_path, branch) do
    # Worktrees live next to the bare repo under a "worktrees/" directory
    repo_dir = Path.dirname(bare_path)
    safe_branch = String.replace(branch, "/", "-")
    path = Path.join([repo_dir, "worktrees", safe_branch])
    {:ok, path}
  end
end
