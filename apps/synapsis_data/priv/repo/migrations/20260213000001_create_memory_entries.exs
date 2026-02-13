defmodule Synapsis.Repo.Migrations.CreateMemoryEntries do
  use Ecto.Migration

  def change do
    create table(:memory_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :scope, :text, null: false
      add :scope_id, :binary_id
      add :key, :text, null: false
      add :content, :text, null: false
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:memory_entries, [:scope, :scope_id])
    create unique_index(:memory_entries, [:scope, :scope_id, :key])
  end
end
