defmodule Synapsis.Repo.Migrations.AddMissingIndexes do
  use Ecto.Migration

  def change do
    # memory_events: frequently queried by correlation_id in summarizer_dispatcher
    create_if_not_exists(index(:memory_events, [:correlation_id]))

    # workspace_documents: cleanup queries filter on deleted_at
    create_if_not_exists(
      index(:workspace_documents, [:deleted_at], where: "deleted_at IS NOT NULL")
    )

    # plugin_configs: startup query filters on auto_start
    create_if_not_exists(index(:plugin_configs, [:auto_start], where: "auto_start = true"))
  end
end
