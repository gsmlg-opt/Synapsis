defmodule Synapsis.Repo.Migrations.AddMissingIndexes do
  use Ecto.Migration

  def change do
    # sessions.project_id is frequently queried alone
    create_if_not_exists index(:sessions, [:project_id])

    # plugin_configs.scope is filtered in list queries
    create_if_not_exists index(:plugin_configs, [:scope])
  end
end
