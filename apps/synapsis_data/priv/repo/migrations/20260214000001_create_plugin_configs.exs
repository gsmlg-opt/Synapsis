defmodule Synapsis.Repo.Migrations.CreatePluginConfigs do
  use Ecto.Migration

  def change do
    create table(:plugin_configs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :type, :string, null: false
      add :name, :string, null: false
      add :transport, :string, default: "stdio"
      add :command, :string
      add :args, :jsonb, default: "[]"
      add :url, :string
      add :root_path, :string
      add :env, :map, default: %{}
      add :settings, :map, default: %{}
      add :auto_start, :boolean, default: false
      add :scope, :string, default: "project"
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:plugin_configs, [:name, :scope, :project_id])
    create index(:plugin_configs, [:type])
    create index(:plugin_configs, [:project_id])
  end
end
