defmodule Synapsis.Repo.Migrations.CreateSessionPermissions do
  use Ecto.Migration

  def change do
    create table(:session_permissions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all), null: false
      add :mode, :string, size: 50, null: false, default: "interactive"
      add :allow_write, :boolean, null: false, default: true
      add :allow_execute, :boolean, null: false, default: true
      add :allow_destructive, :string, size: 50, null: false, default: "ask"
      add :tool_overrides, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:session_permissions, [:session_id])
  end
end
