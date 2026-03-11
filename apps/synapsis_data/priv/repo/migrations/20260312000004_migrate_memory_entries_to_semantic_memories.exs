defmodule Synapsis.Repo.Migrations.MigrateMemoryEntriesToSemanticMemories do
  use Ecto.Migration

  def up do
    # Migrate existing memory_entries into semantic_memories
    # Cast scope_id from uuid to text, handle NULL as empty string
    execute("""
    INSERT INTO semantic_memories (id, scope, scope_id, kind, title, summary, detail, tags,
      evidence_event_ids, importance, confidence, freshness, source, contributed_by,
      access_count, inserted_at, updated_at)
    SELECT
      id,
      CASE scope WHEN 'global' THEN 'shared' ELSE scope END,
      COALESCE(scope_id::text, ''),
      'fact',
      key,
      content,
      COALESCE(metadata, '{}'::jsonb),
      ARRAY[]::text[],
      ARRAY[]::text[],
      1.0,
      1.0,
      1.0,
      'human',
      NULL,
      0,
      inserted_at,
      updated_at
    FROM memory_entries
    WHERE scope != 'session'
    """)

    # Drop the old table
    drop table(:memory_entries)
  end

  def down do
    # Recreate memory_entries table
    create table(:memory_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :scope, :string
      add :scope_id, :binary_id
      add :key, :string
      add :content, :string
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:memory_entries, [:scope, :scope_id, :key])

    # Migrate back
    execute("""
    INSERT INTO memory_entries (id, scope, scope_id, key, content, metadata, inserted_at, updated_at)
    SELECT
      id,
      CASE scope WHEN 'shared' THEN 'global' ELSE scope END,
      CASE WHEN scope_id = '' THEN NULL ELSE scope_id::uuid END,
      title,
      summary,
      detail,
      inserted_at,
      updated_at
    FROM semantic_memories
    WHERE source = 'human'
    """)
  end
end
