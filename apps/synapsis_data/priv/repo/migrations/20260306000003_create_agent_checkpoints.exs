defmodule Synapsis.Repo.Migrations.CreateAgentCheckpoints do
  use Ecto.Migration

  def change do
    create table(:agent_checkpoints, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :run_id, :string, null: false
      add :graph, :map, null: false
      add :node, :string
      add :status, :string, null: false
      add :state, :map, default: %{}, null: false
      add :ctx, :map, default: %{}, null: false
      add :error, :map

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_checkpoints, [:run_id])
  end
end
