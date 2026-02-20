defmodule Synapsis.Repo.Migrations.CreateFailedAttempts do
  use Ecto.Migration

  def change do
    create table(:failed_attempts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all), null: false
      add :attempt_number, :integer, null: false
      add :tool_call_hash, :string
      add :tool_calls_snapshot, :map, default: %{}
      add :error_message, :text
      add :lesson, :text
      add :triggered_by, :string
      add :auditor_model, :string

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:failed_attempts, [:session_id])
    create index(:failed_attempts, [:session_id, :attempt_number])
  end
end
