defmodule Synapsis.Workspace.Resources do
  @moduledoc """
  CRUD operations for `workspace_documents` with version history management.

  All database access is delegated to `Synapsis.WorkspaceDocuments`.
  """

  alias Synapsis.WorkspaceDocument
  alias Synapsis.WorkspaceDocuments
  alias Synapsis.Workspace.PathResolver

  @doc """
  Get a document by path (active, non-deleted).
  """
  @spec get_by_path(String.t()) :: {:ok, WorkspaceDocument.t()} | {:error, :not_found}
  def get_by_path(path) do
    path = PathResolver.normalize_path(path)

    case WorkspaceDocuments.get_by_path(path) do
      nil -> {:error, :not_found}
      doc -> {:ok, doc}
    end
  end

  @doc """
  Get a document by ID.
  """
  @spec get_by_id(String.t()) :: {:ok, WorkspaceDocument.t()} | {:error, :not_found}
  def get_by_id(id) do
    case WorkspaceDocuments.get(id) do
      nil -> {:error, :not_found}
      doc -> {:ok, doc}
    end
  end

  @doc """
  Create or update a document at the given path.
  If a document exists at the path, it is updated (with version history).
  If not, a new document is created.
  """
  @spec upsert(String.t(), String.t() | nil, map()) ::
          {:ok, WorkspaceDocument.t()} | {:error, Ecto.Changeset.t()}
  def upsert(path, content, opts \\ %{}) do
    path = PathResolver.normalize_path(path)

    case get_by_path(path) do
      {:ok, doc} -> update_document(doc, content, opts)
      {:error, :not_found} -> create_document(path, content, opts)
    end
  end

  @doc """
  Create a new document.
  """
  @spec create_document(String.t(), String.t() | nil, map()) ::
          {:ok, WorkspaceDocument.t()} | {:error, Ecto.Changeset.t()}
  def create_document(path, content, opts \\ %{}) do
    path = PathResolver.normalize_path(path)

    with {:ok, resolved} <- PathResolver.resolve(path) do
      kind = Map.get(opts, :kind) || PathResolver.derive_kind(resolved.segments)
      author = Map.get(opts, :author, "system")

      attrs = %{
        path: path,
        kind: kind,
        content_body: content,
        blob_ref: Map.get(opts, :blob_ref),
        content_format: Map.get(opts, :content_format, :markdown),
        visibility: Map.get(opts, :visibility, resolved.default_visibility),
        lifecycle: Map.get(opts, :lifecycle, resolved.default_lifecycle),
        metadata: Map.get(opts, :metadata, %{}),
        project_id: resolved.project_id,
        session_id: resolved.session_id,
        created_by: author,
        updated_by: author,
        version: 1
      }

      %WorkspaceDocument{}
      |> WorkspaceDocument.create_changeset(attrs)
      |> WorkspaceDocuments.insert()
    end
  end

  @doc """
  Update an existing document, creating a version snapshot if warranted by lifecycle.
  """
  @spec update_document(WorkspaceDocument.t(), String.t() | nil, map()) ::
          {:ok, WorkspaceDocument.t()} | {:error, Ecto.Changeset.t()}
  def update_document(doc, content, opts \\ %{}) do
    author = Map.get(opts, :author, "system")

    WorkspaceDocuments.transaction(fn ->
      maybe_create_version(doc)

      # Note: version is managed by optimistic_lock in update_changeset
      attrs =
        %{
          content_body: content,
          updated_by: author
        }
        |> maybe_put(:blob_ref, opts)
        |> maybe_put(:metadata, opts)
        |> maybe_put(:visibility, opts)
        |> maybe_put(:lifecycle, opts)
        |> maybe_put(:content_format, opts)

      case doc |> WorkspaceDocument.update_changeset(attrs) |> WorkspaceDocuments.update() do
        {:ok, updated} -> updated
        {:error, changeset} -> WorkspaceDocuments.rollback(changeset)
      end
    end)
  end

  @doc """
  Move a document to a new path.
  """
  @spec move(WorkspaceDocument.t(), String.t()) ::
          {:ok, WorkspaceDocument.t()} | {:error, Ecto.Changeset.t()}
  def move(doc, new_path) do
    new_path = PathResolver.normalize_path(new_path)

    with {:ok, resolved} <- PathResolver.resolve(new_path) do
      attrs = %{
        path: new_path,
        project_id: resolved.project_id,
        session_id: resolved.session_id
      }

      doc
      |> WorkspaceDocument.changeset(attrs)
      |> WorkspaceDocuments.update()
    end
  end

  @doc """
  Soft-delete a document.
  """
  @spec soft_delete(WorkspaceDocument.t()) ::
          {:ok, WorkspaceDocument.t()} | {:error, Ecto.Changeset.t()}
  def soft_delete(doc) do
    WorkspaceDocuments.soft_delete(doc)
  end

  @doc """
  List documents under a path prefix.
  """
  @spec list(String.t(), keyword()) :: [WorkspaceDocument.t()]
  def list(path_prefix, opts \\ []) do
    path_prefix = PathResolver.normalize_path(path_prefix)
    prefix = if String.ends_with?(path_prefix, "/"), do: path_prefix, else: path_prefix <> "/"
    WorkspaceDocuments.list_by_prefix(prefix, opts)
  end

  # Version history management based on lifecycle
  defp maybe_create_version(%WorkspaceDocument{lifecycle: :scratch}), do: :skip

  defp maybe_create_version(%WorkspaceDocument{} = doc) do
    content_hash = hash_content(doc.content_body || "")

    WorkspaceDocuments.insert_version!(%{
      document_id: doc.id,
      version: doc.version,
      content_body: doc.content_body,
      blob_ref: doc.blob_ref,
      content_hash: content_hash,
      changed_by: doc.updated_by
    })

    # Prune old versions for drafts (configurable retention)
    if doc.lifecycle == :draft do
      keep = draft_version_retention()
      WorkspaceDocuments.prune_versions(doc.id, keep)
    end
  end

  defp draft_version_retention do
    :synapsis_workspace
    |> Application.get_env(:gc, [])
    |> Keyword.get(:draft_version_retention, 5)
  end

  defp hash_content(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp maybe_put(attrs, key, opts) do
    case Map.get(opts, key) do
      nil -> attrs
      value -> Map.put(attrs, key, value)
    end
  end
end
