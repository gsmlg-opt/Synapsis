defmodule Synapsis.Repos do
  @moduledoc "Data context for git repositories."

  import Ecto.Query
  alias Synapsis.{Repo, RepoRecord, RepoRemote, RepoWorktree}

  @spec create(binary(), map()) :: {:ok, RepoRecord.t()} | {:error, Ecto.Changeset.t()}
  def create(project_id, attrs) do
    attrs = Map.put(attrs, :project_id, project_id)
    %RepoRecord{} |> RepoRecord.changeset(attrs) |> Repo.insert()
  end

  @spec get(binary()) :: RepoRecord.t() | nil
  def get(id), do: Repo.get(RepoRecord, id)

  @spec get_with_remotes(binary()) :: RepoRecord.t() | nil
  def get_with_remotes(id) do
    RepoRecord
    |> Repo.get(id)
    |> case do
      nil -> nil
      record -> Repo.preload(record, :remotes)
    end
  end

  @spec list_for_project(binary()) :: [RepoRecord.t()]
  def list_for_project(project_id) do
    from(r in RepoRecord,
      where: r.project_id == ^project_id and r.status == :active,
      order_by: [asc: r.name]
    )
    |> Repo.all()
  end

  @spec add_remote(binary(), map()) :: {:ok, RepoRemote.t()} | {:error, Ecto.Changeset.t()}
  def add_remote(repo_id, attrs) do
    attrs = Map.put(attrs, :repo_id, repo_id)
    %RepoRemote{} |> RepoRemote.changeset(attrs) |> Repo.insert()
  end

  @spec remove_remote(binary()) :: {:ok, RepoRemote.t()} | {:error, term()}
  def remove_remote(remote_id) do
    case Repo.get(RepoRemote, remote_id) do
      nil -> {:error, :not_found}
      remote -> Repo.delete(remote)
    end
  end

  @spec set_primary_remote(binary()) :: {:ok, RepoRemote.t()} | {:error, term()}
  def set_primary_remote(remote_id) do
    Repo.transaction(fn ->
      case Repo.get(RepoRemote, remote_id) do
        nil ->
          Repo.rollback(:not_found)

        remote ->
          from(r in RepoRemote, where: r.repo_id == ^remote.repo_id)
          |> Repo.update_all(set: [is_primary: false])

          case remote |> Ecto.Changeset.change(is_primary: true) |> Repo.update() do
            {:ok, updated} -> updated
            {:error, cs} -> Repo.rollback(cs)
          end
      end
    end)
  end

  @spec archive(RepoRecord.t()) :: {:ok, RepoRecord.t()} | {:error, term()}
  def archive(%RepoRecord{} = repo) do
    active_worktrees_count =
      from(w in RepoWorktree, where: w.repo_id == ^repo.id and w.status == :active)
      |> Repo.aggregate(:count, :id)

    if active_worktrees_count > 0 do
      {:error, :active_worktrees_exist}
    else
      repo |> RepoRecord.changeset(%{status: :archived}) |> Repo.update()
    end
  end
end
