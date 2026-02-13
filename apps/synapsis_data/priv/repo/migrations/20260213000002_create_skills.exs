defmodule Synapsis.Repo.Migrations.CreateSkills do
  use Ecto.Migration

  def change do
    create table(:skills, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :scope, :text, null: false, default: "global"
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all)
      add :name, :text, null: false
      add :description, :text
      add :system_prompt_fragment, :text
      add :tool_allowlist, :jsonb, default: "[]"
      add :config_overrides, :map, default: %{}
      add :is_builtin, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:skills, [:scope])
    create index(:skills, [:project_id])
    create unique_index(:skills, [:scope, :project_id, :name])
  end
end
