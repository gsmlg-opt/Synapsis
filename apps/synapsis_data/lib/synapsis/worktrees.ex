defmodule Synapsis.Worktrees do
  @moduledoc "Data context for git worktrees."

  import Ecto.Query
  alias Synapsis.{Repo, RepoRecord, RepoWorktree}

  @spec create(binary(), map()) :: {:ok, RepoWorktree.t()} | {:error, Ecto.Changeset.t()}
  def create(repo_id, attrs) do
    attrs = Map.put(attrs, :repo_id, repo_id)
    %RepoWorktree{} |> RepoWorktree.changeset(attrs) |> Repo.insert()
  end

  @spec get(binary()) :: RepoWorktree.t() | nil
  def get(id), do: Repo.get(RepoWorktree, id)

  @spec list_active_for_repo(binary()) :: [RepoWorktree.t()]
  def list_active_for_repo(repo_id) do
    from(w in RepoWorktree,
      where: w.repo_id == ^repo_id and w.status == :active,
      order_by: [asc: w.inserted_at]
    )
    |> Repo.all()
  end

  @spec list_active_for_project(binary()) :: [RepoWorktree.t()]
  def list_active_for_project(project_id) do
    from(w in RepoWorktree,
      join: r in RepoRecord,
      on: w.repo_id == r.id,
      where: r.project_id == ^project_id and w.status == :active,
      order_by: [asc: w.inserted_at]
    )
    |> Repo.all()
  end

  @spec mark_completed(RepoWorktree.t()) ::
          {:ok, RepoWorktree.t()} | {:error, Ecto.Changeset.t()}
  def mark_completed(%RepoWorktree{status: :active} = worktree) do
    worktree
    |> RepoWorktree.changeset(%{status: :completed, completed_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def mark_completed(%RepoWorktree{} = worktree) do
    {:error,
     worktree
     |> RepoWorktree.changeset(%{})
     |> Ecto.Changeset.add_error(:status, "must be active to mark completed")}
  end

  @spec mark_failed(RepoWorktree.t()) :: {:ok, RepoWorktree.t()} | {:error, Ecto.Changeset.t()}
  def mark_failed(%RepoWorktree{status: :active} = worktree) do
    worktree
    |> RepoWorktree.changeset(%{status: :failed, completed_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def mark_failed(%RepoWorktree{} = worktree) do
    {:error,
     worktree
     |> RepoWorktree.changeset(%{})
     |> Ecto.Changeset.add_error(:status, "must be active to mark failed")}
  end

  @spec mark_cleaning(RepoWorktree.t()) ::
          {:ok, RepoWorktree.t()} | {:error, Ecto.Changeset.t()}
  def mark_cleaning(%RepoWorktree{status: status} = worktree)
      when status in [:completed, :failed] do
    worktree
    |> RepoWorktree.changeset(%{status: :cleaning})
    |> Repo.update()
  end

  def mark_cleaning(%RepoWorktree{} = worktree) do
    {:error,
     worktree
     |> RepoWorktree.changeset(%{})
     |> Ecto.Changeset.add_error(:status, "must be completed or failed to mark cleaning")}
  end

  @spec mark_cleaned(RepoWorktree.t()) :: {:ok, RepoWorktree.t()} | {:error, Ecto.Changeset.t()}
  def mark_cleaned(%RepoWorktree{status: :cleaning} = worktree) do
    worktree
    |> RepoWorktree.changeset(%{cleaned_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def mark_cleaned(%RepoWorktree{} = worktree) do
    {:error,
     worktree
     |> RepoWorktree.changeset(%{})
     |> Ecto.Changeset.add_error(:status, "must be cleaning to mark cleaned")}
  end

  @spec assign_agent(RepoWorktree.t(), String.t()) ::
          {:ok, RepoWorktree.t()} | {:error, Ecto.Changeset.t()}
  def assign_agent(%RepoWorktree{} = worktree, session_id) do
    worktree
    |> RepoWorktree.changeset(%{agent_session_id: session_id})
    |> Repo.update()
  end

  @spec stale(pos_integer()) :: [RepoWorktree.t()]
  def stale(age_hours) do
    cutoff = DateTime.add(DateTime.utc_now(), -age_hours * 3600, :second)

    from(w in RepoWorktree,
      where: w.status in [:completed, :failed] and w.completed_at < ^cutoff,
      order_by: [asc: w.completed_at]
    )
    |> Repo.all()
  end
end
