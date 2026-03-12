defmodule Synapsis.WorkspaceDocumentVersion do
  @moduledoc """
  Schema for workspace document version history.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workspace_document_versions" do
    field :version, :integer
    field :content_body, :string
    field :blob_ref, :string
    field :content_hash, :string
    field :changed_by, :string

    belongs_to :document, Synapsis.WorkspaceDocument

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required_fields ~w(document_id version content_hash changed_by)a
  @optional_fields ~w(content_body blob_ref)a

  def changeset(version, attrs) do
    version
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint([:document_id, :version])
  end
end
