defmodule Synapsis.Repo.Migrations.CreateHeartbeatConfigs do
  use Ecto.Migration

  def change do
    create table(:heartbeat_configs, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:name, :string, null: false)
      add(:schedule, :string, null: false)
      add(:agent_type, :string, default: "global")
      add(:project_id, references(:projects, type: :binary_id, on_delete: :delete_all))
      add(:prompt, :text, null: false)
      add(:enabled, :boolean, default: false, null: false)
      add(:notify_user, :boolean, default: true, null: false)
      add(:session_isolation, :string, default: "isolated")
      add(:keep_history, :boolean, default: false, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:heartbeat_configs, [:name]))
    create(index(:heartbeat_configs, [:enabled]))
    create(index(:heartbeat_configs, [:project_id]))
  end
end
