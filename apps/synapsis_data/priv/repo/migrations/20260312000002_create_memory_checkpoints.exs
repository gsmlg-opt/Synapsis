defmodule Synapsis.Repo.Migrations.CreateMemoryCheckpoints do
  use Ecto.Migration

  def change do
    create table(:memory_checkpoints, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :run_id, :string, null: false
      add :session_id, :string, null: false
      add :workflow, :string, null: false
      add :node, :string, null: false
      add :state_version, :integer, null: false
      add :state_format, :string, null: false, default: "json"
      add :state_bytea, :binary
      add :state_json, :map

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:memory_checkpoints, [:run_id, :inserted_at])
    create index(:memory_checkpoints, [:session_id, :inserted_at])
    create index(:memory_checkpoints, [:workflow, :inserted_at])
  end
end
