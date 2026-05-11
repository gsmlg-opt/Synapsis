defmodule Synapsis.Repo.Migrations.CreateAgentRuns do
  use Ecto.Migration

  def change do
    create table(:agent_runs, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:kind, :string, null: false)
      add(:status, :string, null: false, default: "queued")
      add(:source, :string, null: false, default: "system")
      add(:assistant_name, :string)
      add(:session_id, references(:sessions, type: :binary_id, on_delete: :nilify_all))
      add(:project_id, :string)
      add(:heartbeat_id, references(:heartbeat_configs, type: :binary_id, on_delete: :nilify_all))
      add(:routine_id, :binary_id)
      add(:prompt, :text, null: false)
      add(:tool_profile, :string, null: false, default: "read_only")
      add(:model, :string)
      add(:provider, :string)
      add(:summary, :text)
      add(:error, :text)
      add(:started_at, :utc_datetime_usec)
      add(:finished_at, :utc_datetime_usec)
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:agent_runs, [:kind]))
    create(index(:agent_runs, [:status]))
    create(index(:agent_runs, [:source]))
    create(index(:agent_runs, [:session_id]))
    create(index(:agent_runs, [:project_id]))
    create(index(:agent_runs, [:heartbeat_id]))
    create(index(:agent_runs, [:routine_id]))
    create(index(:agent_runs, [:inserted_at]))
  end
end
