defmodule Synapsis.Repo.Migrations.CreateToolsetsAndAgentSkills do
  use Ecto.Migration

  def change do
    create table(:toolsets, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:name, :text, null: false)
      add(:description, :text)
      add(:tool_names, {:array, :text}, default: [])
      add(:is_builtin, :boolean, default: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:toolsets, [:name]))

    alter table(:agent_configs) do
      add(:toolset_id, references(:toolsets, type: :binary_id, on_delete: :nilify_all))
    end

    create(index(:agent_configs, [:toolset_id]))

    create table(:agent_skills, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :agent_config_id,
        references(:agent_configs, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:skill_id, references(:skills, type: :binary_id, on_delete: :delete_all), null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:agent_skills, [:agent_config_id, :skill_id]))
    create(index(:agent_skills, [:skill_id]))
  end
end
