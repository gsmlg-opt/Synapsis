defmodule Synapsis.Repo.Migrations.CreateMessages do
  use Ecto.Migration

  def change do
    create table(:messages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all), null: false
      add :role, :text, null: false
      add :parts, :jsonb, null: false, default: "[]"
      add :token_count, :integer, default: 0

      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:messages, [:session_id, :inserted_at])
  end
end
