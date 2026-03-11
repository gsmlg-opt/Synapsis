defmodule Synapsis.Repo.Migrations.CreateSemanticMemories do
  use Ecto.Migration

  def change do
    create table(:semantic_memories, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :scope, :string, null: false
      add :scope_id, :string, null: false
      add :kind, :string, null: false
      add :title, :string, null: false
      add :summary, :text, null: false
      add :detail, :map, null: false, default: %{}
      add :tags, {:array, :string}, null: false, default: []
      add :evidence_event_ids, {:array, :string}, null: false, default: []
      add :importance, :float, null: false, default: 0.5
      add :confidence, :float, null: false, default: 0.5
      add :freshness, :float, null: false, default: 1.0
      add :source, :string, null: false, default: "agent"
      add :contributed_by, :string
      add :access_count, :integer, null: false, default: 0
      add :last_accessed_at, :utc_datetime_usec
      add :archived_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:semantic_memories, [:scope, :scope_id, :archived_at, :inserted_at])

    # GIN index on tags for array containment queries
    execute(
      "CREATE INDEX semantic_memories_tags_gin ON semantic_memories USING GIN (tags)",
      "DROP INDEX semantic_memories_tags_gin"
    )

    # Full-text search index on title + summary
    execute(
      """
      CREATE INDEX semantic_memories_fts ON semantic_memories
      USING GIN (to_tsvector('english', coalesce(title, '') || ' ' || coalesce(summary, '')))
      """,
      "DROP INDEX semantic_memories_fts"
    )
  end
end
