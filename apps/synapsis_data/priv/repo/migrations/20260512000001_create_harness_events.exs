defmodule Synapsis.Repo.Migrations.CreateHarnessEvents do
  use Ecto.Migration

  def change do
    create table(:harness_events, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:aggregate_id, :binary_id, null: false)
      add(:version, :integer, null: false)
      add(:event_type, :text, null: false)
      add(:schema_version, :integer, null: false, default: 1)
      add(:payload, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:harness_events, [:aggregate_id, :version]))
    create(index(:harness_events, [:aggregate_id, :inserted_at]))
    create(index(:harness_events, [:event_type]))
  end
end
