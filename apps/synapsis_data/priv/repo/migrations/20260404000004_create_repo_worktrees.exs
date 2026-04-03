defmodule Synapsis.Repo.Migrations.CreateRepoWorktrees do
  use Ecto.Migration

  def change do
    create table(:repo_worktrees, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :repo_id, references(:repos, type: :binary_id, on_delete: :restrict), null: false
      add :branch, :string, null: false
      add :base_branch, :string
      add :local_path, :string, null: false
      add :status, :string, null: false, default: "active"
      add :agent_session_id, :string
      add :task_id, :string
      add :metadata, :map, default: %{}
      add :completed_at, :utc_datetime_usec
      add :cleaned_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:repo_worktrees, [:repo_id, :branch],
      where: "status = 'active'",
      name: "repo_worktrees_repo_id_branch_active_index"
    )

    create index(:repo_worktrees, [:repo_id])
    create index(:repo_worktrees, [:status])
  end
end
