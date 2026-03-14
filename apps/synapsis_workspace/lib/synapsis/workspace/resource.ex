defmodule Synapsis.Workspace.Resource do
  @moduledoc """
  Uniform resource struct returned by the workspace API.

  Represents any workspace item — whether backed by `workspace_documents`
  or projected from a domain schema (skills, memory entries, etc.).
  """

  @type visibility :: :private | :project_shared | :global_shared | :published
  @type lifecycle :: :scratch | :draft | :shared | :published | :archived
  @type kind :: :document | :attachment | :handoff | :session_scratch | :skill | :memory | :todo

  @type t :: %__MODULE__{
          id: String.t(),
          path: String.t(),
          kind: kind(),
          content: String.t() | nil,
          metadata: map(),
          visibility: visibility(),
          lifecycle: lifecycle(),
          version: integer(),
          content_format: atom(),
          created_by: String.t() | nil,
          updated_by: String.t() | nil,
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  defstruct [
    :id,
    :path,
    :kind,
    :content,
    :metadata,
    :visibility,
    :lifecycle,
    :version,
    :content_format,
    :created_by,
    :updated_by,
    :created_at,
    :updated_at
  ]

  @doc """
  Build a Resource from a WorkspaceDocument schema.
  """
  def from_document(%Synapsis.WorkspaceDocument{} = doc) do
    %__MODULE__{
      id: doc.id,
      path: doc.path,
      kind: doc.kind,
      content: doc.content_body,
      metadata: doc.metadata || %{},
      visibility: doc.visibility,
      lifecycle: doc.lifecycle,
      version: doc.version,
      content_format: doc.content_format,
      created_by: doc.created_by,
      updated_by: doc.updated_by,
      created_at: doc.inserted_at,
      updated_at: doc.updated_at
    }
  end
end
