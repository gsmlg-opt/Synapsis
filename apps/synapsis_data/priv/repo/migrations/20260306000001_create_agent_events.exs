defmodule Synapsis.Repo.Migrations.CreateAgentEvents do
  use Ecto.Migration

  def change do
    create table(:agent_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :event_type, :string, null: false
      add :project_id, :string
      add :work_id, :string
      add :payload, :map, default: %{}, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:agent_events, [:project_id])
    create index(:agent_events, [:work_id])
    create index(:agent_events, [:event_type])
  end
end
