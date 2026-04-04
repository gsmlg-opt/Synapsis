defmodule Synapsis.Agent.WorktreeCleanup do
  @moduledoc "Oban worker for periodic worktree garbage collection."
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    # Query stale worktrees (completed or failed > 6h ago, as a conservative threshold)
    # stale/1 accepts age_hours and returns worktrees older than that threshold
    stale = Synapsis.Worktrees.stale(6)

    Logger.info("worktree_cleanup_start", count: length(stale))

    Enum.each(stale, fn worktree ->
      cleanup_worktree(worktree)
    end)

    Logger.info("worktree_cleanup_complete", count: length(stale))
    :ok
  end

  defp cleanup_worktree(worktree) do
    Logger.info("worktree_cleanup_attempt",
      worktree_id: worktree.id,
      path: worktree.local_path
    )

    case Synapsis.Worktrees.mark_cleaning(worktree) do
      {:ok, cleaning_wt} ->
        remove_git_worktree(cleaning_wt)

      {:error, reason} ->
        Logger.warning("worktree_cleanup_mark_cleaning_failed",
          worktree_id: worktree.id,
          reason: inspect(reason)
        )
    end
  end

  defp remove_git_worktree(worktree) do
    path = worktree.local_path

    if path && File.dir?(path) do
      case System.cmd("git", ["worktree", "remove", "--force", path]) do
        {_, 0} ->
          finalize_cleanup(worktree)

        {output, code} ->
          Logger.warning("worktree_git_remove_failed",
            worktree_id: worktree.id,
            path: path,
            exit_code: code,
            output: output
          )
      end
    else
      finalize_cleanup(worktree)
    end
  end

  defp finalize_cleanup(worktree) do
    case Synapsis.Worktrees.mark_cleaned(worktree) do
      {:ok, _} ->
        Logger.info("worktree_cleanup_done", worktree_id: worktree.id)

      {:error, reason} ->
        Logger.warning("worktree_cleanup_mark_cleaned_failed",
          worktree_id: worktree.id,
          reason: inspect(reason)
        )
    end
  end
end
