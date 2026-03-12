defmodule Synapsis.Repo.Migrations.CreateMemoryEvents do
  use Ecto.Migration

  def change do
    create table(:memory_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :scope, :string, null: false
      add :scope_id, :string, null: false
      add :agent_id, :string, null: false
      add :run_id, :string
      add :type, :string, null: false
      add :importance, :float, null: false, default: 0.5
      add :payload, :map, null: false, default: %{}
      add :causation_id, :string
      add :correlation_id, :string

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:memory_events, [:scope, :scope_id, :inserted_at])
    create index(:memory_events, [:run_id, :inserted_at])
    create index(:memory_events, [:agent_id, :inserted_at])
    create index(:memory_events, [:type, :inserted_at])
  end
end
