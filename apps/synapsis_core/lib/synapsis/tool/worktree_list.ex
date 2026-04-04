defmodule Synapsis.Tool.WorktreeList do
  @moduledoc "List active git worktrees for a repository."
  use Synapsis.Tool

  @impl true
  def name, do: "worktree_list"

  @impl true
  def description,
    do: "List all active git worktrees for a repository."

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
          "description" => "The repository ID to list worktrees for"
        }
      },
      "required" => ["repo_id"]
    }
  end

  @impl true
  def execute(input, _context) do
    repo_id = Map.get(input, "repo_id")

    worktrees =
      Synapsis.Worktrees.list_active_for_repo(repo_id)
      |> Enum.map(fn wt ->
        %{
          id: wt.id,
          branch: wt.branch,
          base_branch: wt.base_branch,
          local_path: wt.local_path,
          status: wt.status,
          task_id: wt.task_id,
          agent_session_id: wt.agent_session_id,
          inserted_at: DateTime.to_iso8601(wt.inserted_at)
        }
      end)

    {:ok, Jason.encode!(worktrees)}
  end
end
