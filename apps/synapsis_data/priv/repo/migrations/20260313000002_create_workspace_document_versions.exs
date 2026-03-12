defmodule Synapsis.Repo.Migrations.CreateWorkspaceDocumentVersions do
  use Ecto.Migration

  def change do
    create table(:workspace_document_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :document_id, references(:workspace_documents, type: :binary_id, on_delete: :delete_all),
        null: false
      add :version, :integer, null: false
      add :content_body, :text
      add :blob_ref, :text
      add :content_hash, :text, null: false
      add :changed_by, :text, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:workspace_document_versions, [:document_id])
    create unique_index(:workspace_document_versions, [:document_id, :version])
  end
end
