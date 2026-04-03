defmodule Synapsis.Repo.Migrations.CreateRepoRemotes do
  use Ecto.Migration

  def change do
    create table(:repo_remotes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :repo_id, references(:repos, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :url, :string, null: false
      add :push_url, :string
      add :is_primary, :boolean, default: false, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:repo_remotes, [:repo_id, :name])
    create index(:repo_remotes, [:repo_id])
  end
end
