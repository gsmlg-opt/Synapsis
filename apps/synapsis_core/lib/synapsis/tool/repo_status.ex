defmodule Synapsis.Tool.RepoStatus do
  @moduledoc "Get status summary for a linked repository: branches, recent commits, active worktrees."
  use Synapsis.Tool

  @impl true
  def name, do: "repo_status"

  @impl true
  def description,
    do:
      "Get a status summary for a linked repository including branches, recent commits, " <>
        "and active worktree count."

  @impl true
  def permission_level, do: :none

  @impl true
  def category, do: :workflow

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "repo_id" => %{
          "type" => "string",
          "description" => "The repository ID to inspect"
        },
        "commit_count" => %{
          "type" => "integer",
          "description" => "Number of recent commits to include (default 10)"
        }
      },
      "required" => ["repo_id"]
    }
  end

  @impl true
  def execute(input, _context) do
    repo_id = Map.get(input, "repo_id")
    commit_count = Map.get(input, "commit_count", 10)

    case Synapsis.Repos.get_with_remotes(repo_id) do
      nil ->
        {:error, "Repository #{repo_id} not found"}

      repo ->
        branches =
          case Synapsis.Git.Branch.list(repo.bare_path) do
            {:ok, list} -> list
            {:error, _} -> []
          end

        recent_commits =
          case Synapsis.Git.Log.recent(repo.bare_path, limit: commit_count) do
            {:ok, commits} -> commits
            {:error, _} -> []
          end

        active_worktrees = Synapsis.Worktrees.list_active_for_repo(repo.id)

        remotes =
          Enum.map(repo.remotes || [], fn r ->
            %{name: r.name, url: r.url, is_primary: r.is_primary}
          end)

        result = %{
          repo_id: repo.id,
          name: repo.name,
          bare_path: repo.bare_path,
          default_branch: repo.default_branch,
          status: repo.status,
          remotes: remotes,
          branches: branches,
          branch_count: length(branches),
          recent_commits: recent_commits,
          active_worktree_count: length(active_worktrees)
        }

        {:ok, Jason.encode!(result)}
    end
  end
end
