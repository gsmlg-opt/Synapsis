defmodule Synapsis.Repo.Migrations.AlterProjectsAddFields do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :name, :string
      add :description, :text
      add :status, :string, null: false, default: "active"
      add :metadata, :map, default: %{}
    end

    execute(
      "UPDATE projects SET name = slug WHERE name IS NULL",
      "UPDATE projects SET name = NULL WHERE name = slug"
    )

    alter table(:projects) do
      modify :name, :string, null: false
    end

    create unique_index(:projects, [:name])
  end
end
