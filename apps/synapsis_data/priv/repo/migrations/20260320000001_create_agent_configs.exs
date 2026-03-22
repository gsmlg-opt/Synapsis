defmodule Synapsis.Repo.Migrations.CreateAgentConfigs do
  use Ecto.Migration

  def change do
    create table(:agent_configs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      add :label, :text
      add :icon, :text, default: "robot-outline"
      add :description, :text
      add :provider, :text
      add :model, :text
      add :system_prompt, :text
      add :tools, {:array, :text}, default: []
      add :reasoning_effort, :text, default: "medium"
      add :read_only, :boolean, default: false
      add :max_tokens, :integer, default: 8192
      add :model_tier, :text, default: "default"
      add :fallback_models, :text, default: ""
      add :is_default, :boolean, default: false
      add :enabled, :boolean, default: true
      add :config, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_configs, [:name])
  end
end
