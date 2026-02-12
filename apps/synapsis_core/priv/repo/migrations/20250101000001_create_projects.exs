defmodule Synapsis.Repo.Migrations.CreateProjects do
  use Ecto.Migration

  def change do
    create table(:projects, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :path, :text, null: false
      add :slug, :text, null: false
      add :config, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:projects, [:path])
    create unique_index(:projects, [:slug])
  end
end
