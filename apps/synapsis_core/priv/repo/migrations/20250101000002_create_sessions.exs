defmodule Synapsis.Repo.Migrations.CreateSessions do
  use Ecto.Migration

  def change do
    create table(:sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: false
      add :title, :text
      add :agent, :text, null: false, default: "build"
      add :provider, :text, null: false
      add :model, :text, null: false
      add :status, :text, null: false, default: "idle"
      add :config, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:sessions, [:project_id, :updated_at])
  end
end
