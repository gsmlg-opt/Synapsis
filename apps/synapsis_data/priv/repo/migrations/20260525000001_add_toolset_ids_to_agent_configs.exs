defmodule Synapsis.Repo.Migrations.AddToolsetIdsToAgentConfigs do
  use Ecto.Migration

  def up do
    alter table(:agent_configs) do
      add(:toolset_ids, {:array, :text}, null: false, default: [])
    end

    execute("""
    UPDATE agent_configs
    SET toolset_ids = ARRAY[toolset_id::text]
    WHERE toolset_id IS NOT NULL
    """)
  end

  def down do
    alter table(:agent_configs) do
      remove(:toolset_ids)
    end
  end
end
