defmodule Synapsis.Repo.Migrations.CreatePatches do
  use Ecto.Migration

  def change do
    create table(:patches, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all), null: false
      add :failed_attempt_id, references(:failed_attempts, type: :binary_id, on_delete: :nilify_all)
      add :file_path, :string, null: false
      add :diff_text, :text, null: false
      add :git_commit_hash, :string
      add :test_status, :string, default: "pending"
      add :test_output, :text
      add :reverted_at, :utc_datetime_usec
      add :revert_reason, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:patches, [:session_id])
    create index(:patches, [:failed_attempt_id])
    create index(:patches, [:session_id, :test_status])
  end
end
