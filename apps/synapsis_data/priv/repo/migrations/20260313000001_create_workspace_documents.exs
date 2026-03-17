defmodule Synapsis.Repo.Migrations.CreateWorkspaceDocuments do
  use Ecto.Migration

  def change do
    execute(
      "CREATE TYPE workspace_document_kind AS ENUM ('document', 'attachment', 'handoff', 'session_scratch')",
      "DROP TYPE workspace_document_kind"
    )

    execute(
      "CREATE TYPE workspace_visibility AS ENUM ('private', 'project_shared', 'global_shared', 'published')",
      "DROP TYPE workspace_visibility"
    )

    execute(
      "CREATE TYPE workspace_lifecycle AS ENUM ('scratch', 'draft', 'shared', 'published', 'archived')",
      "DROP TYPE workspace_lifecycle"
    )

    execute(
      "CREATE TYPE workspace_content_format AS ENUM ('markdown', 'yaml', 'json', 'text', 'binary')",
      "DROP TYPE workspace_content_format"
    )

    create table(:workspace_documents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :path, :text, null: false
      add :kind, :workspace_document_kind, null: false, default: "document"
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all)
      add :session_id, references(:sessions, type: :binary_id, on_delete: :nilify_all)
      add :visibility, :workspace_visibility, null: false, default: "private"
      add :lifecycle, :workspace_lifecycle, null: false, default: "draft"
      add :content_format, :workspace_content_format, null: false, default: "markdown"
      add :content_body, :text
      add :blob_ref, :text
      add :metadata, :map, default: %{}
      add :version, :integer, default: 1, null: false
      add :created_by, :text, null: false
      add :updated_by, :text, null: false
      add :last_accessed_at, :utc_datetime_usec
      add :deleted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # Unique path index excluding soft-deleted records
    create unique_index(:workspace_documents, [:path],
             where: "deleted_at IS NULL",
             name: :workspace_documents_path_unique_active
           )

    create index(:workspace_documents, [:project_id])
    create index(:workspace_documents, [:session_id])
    create index(:workspace_documents, [:kind])
    create index(:workspace_documents, [:lifecycle])
    create index(:workspace_documents, [:visibility])

    # Full-text search vector
    execute(
      """
      ALTER TABLE workspace_documents ADD COLUMN search_vector tsvector
      GENERATED ALWAYS AS (
        setweight(to_tsvector('english', coalesce(path, '')), 'A') ||
        setweight(to_tsvector('english', coalesce(metadata->>'title', '')), 'B') ||
        setweight(to_tsvector('english', coalesce(content_body, '')), 'C')
      ) STORED
      """,
      "ALTER TABLE workspace_documents DROP COLUMN search_vector"
    )

    execute(
      "CREATE INDEX workspace_documents_search_idx ON workspace_documents USING GIN (search_vector)",
      "DROP INDEX workspace_documents_search_idx"
    )
  end
end
