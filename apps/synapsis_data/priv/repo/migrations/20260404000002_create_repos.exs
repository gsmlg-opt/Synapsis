defmodule Synapsis.Repo.Migrations.CreateRepos do
  use Ecto.Migration

  def change do
    create table(:repos, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, type: :binary_id, on_delete: :restrict), null: false
      add :name, :string, null: false
      add :bare_path, :string, null: false
      add :default_branch, :string, null: false, default: "main"
      add :status, :string, null: false, default: "active"
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:repos, [:project_id, :name])
    create index(:repos, [:project_id])
  end
end
