defmodule Synapsis.WorkspaceDocument do
  @moduledoc """
  Schema for workspace documents — the backing store for unstructured workspace content
  (notes, plans, ideas, scratch, handoffs, attachments).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kind_values ~w(document attachment handoff session_scratch)a
  @visibility_values ~w(private project_shared global_shared published)a
  @lifecycle_values ~w(scratch draft shared published archived)a
  @content_format_values ~w(markdown yaml json text binary)a

  schema "workspace_documents" do
    field :path, :string
    field :kind, Ecto.Enum, values: @kind_values, default: :document
    field :visibility, Ecto.Enum, values: @visibility_values, default: :private
    field :lifecycle, Ecto.Enum, values: @lifecycle_values, default: :draft
    field :content_format, Ecto.Enum, values: @content_format_values, default: :markdown
    field :content_body, :string
    field :blob_ref, :string
    field :metadata, :map, default: %{}
    field :version, :integer, default: 1
    field :created_by, :string
    field :updated_by, :string
    field :last_accessed_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec

    belongs_to :project, Synapsis.Project
    belongs_to :session, Synapsis.Session

    has_many :versions, Synapsis.WorkspaceDocumentVersion, foreign_key: :document_id

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields ~w(path created_by updated_by)a
  @optional_fields ~w(kind visibility lifecycle content_format content_body blob_ref
                       metadata version project_id session_id last_accessed_at deleted_at)a

  def changeset(document, attrs) do
    document
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_path()
    |> unique_constraint(:path, name: :workspace_documents_path_unique_active)
  end

  def create_changeset(document, attrs) do
    document
    |> changeset(attrs)
    |> put_change(:version, 1)
  end

  def update_changeset(document, attrs) do
    document
    |> changeset(attrs)
    |> optimistic_lock(:version)
  end

  def soft_delete_changeset(document) do
    change(document, deleted_at: DateTime.utc_now())
  end

  defp validate_path(changeset) do
    changeset
    |> validate_format(:path, ~r|^/|, message: "must start with /")
    |> validate_length(:path, min: 2, max: 1024)
  end
end
