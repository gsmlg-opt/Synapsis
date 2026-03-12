defmodule Synapsis.Workspace.Resources do
  @moduledoc """
  CRUD operations for `workspace_documents` with version history management.
  """

  import Ecto.Query
  alias Synapsis.Repo
  alias Synapsis.WorkspaceDocument
  alias Synapsis.WorkspaceDocumentVersion
  alias Synapsis.Workspace.PathResolver

  @doc """
  Get a document by path (active, non-deleted).
  """
  @spec get_by_path(String.t()) :: {:ok, WorkspaceDocument.t()} | {:error, :not_found}
  def get_by_path(path) do
    path = PathResolver.normalize_path(path)

    query =
      from d in WorkspaceDocument,
        where: d.path == ^path and is_nil(d.deleted_at)

    case Repo.one(query) do
      nil -> {:error, :not_found}
      doc -> {:ok, doc}
    end
  end

  @doc """
  Get a document by ID.
  """
  @spec get_by_id(String.t()) :: {:ok, WorkspaceDocument.t()} | {:error, :not_found}
  def get_by_id(id) do
    case Repo.get(WorkspaceDocument, id) do
      nil -> {:error, :not_found}
      %{deleted_at: deleted_at} = _doc when not is_nil(deleted_at) -> {:error, :not_found}
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
      |> Repo.insert()
    end
  end

  @doc """
  Update an existing document, creating a version snapshot if warranted by lifecycle.
  """
  @spec update_document(WorkspaceDocument.t(), String.t() | nil, map()) ::
          {:ok, WorkspaceDocument.t()} | {:error, Ecto.Changeset.t()}
  def update_document(doc, content, opts \\ %{}) do
    author = Map.get(opts, :author, "system")
    new_version = doc.version + 1

    Repo.transaction(fn ->
      maybe_create_version(doc)

      attrs =
        %{
          content_body: content,
          updated_by: author,
          version: new_version
        }
        |> maybe_put(:metadata, opts)
        |> maybe_put(:visibility, opts)
        |> maybe_put(:lifecycle, opts)
        |> maybe_put(:content_format, opts)

      case doc |> WorkspaceDocument.changeset(attrs) |> Repo.update() do
        {:ok, updated} -> updated
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Soft-delete a document.
  """
  @spec soft_delete(WorkspaceDocument.t()) ::
          {:ok, WorkspaceDocument.t()} | {:error, Ecto.Changeset.t()}
  def soft_delete(doc) do
    doc
    |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
    |> Repo.update()
  end

  @doc """
  List documents under a path prefix.
  """
  @spec list(String.t(), keyword()) :: [WorkspaceDocument.t()]
  def list(path_prefix, opts \\ []) do
    path_prefix = PathResolver.normalize_path(path_prefix)
    prefix = if String.ends_with?(path_prefix, "/"), do: path_prefix, else: path_prefix <> "/"
    depth = Keyword.get(opts, :depth)
    kind = Keyword.get(opts, :kind)
    sort = Keyword.get(opts, :sort, :path)
    limit = Keyword.get(opts, :limit, 100)

    query =
      from d in WorkspaceDocument,
        where: like(d.path, ^"#{prefix}%") and is_nil(d.deleted_at),
        limit: ^limit

    query = if kind, do: where(query, [d], d.kind == ^kind), else: query

    query =
      if depth do
        # Count path segments after prefix to limit depth
        segment_count = prefix |> String.split("/", trim: true) |> length()
        max_segments = segment_count + depth

        where(
          query,
          [d],
          fragment(
            "array_length(string_to_array(trim(both '/' from ?), '/'), 1) <= ?",
            d.path,
            ^max_segments
          )
        )
      else
        query
      end

    query =
      case sort do
        :recent -> order_by(query, [d], desc: d.updated_at)
        :name -> order_by(query, [d], asc: d.path)
        _ -> order_by(query, [d], asc: d.path)
      end

    Repo.all(query)
  end

  # Version history management based on lifecycle
  defp maybe_create_version(%WorkspaceDocument{lifecycle: :scratch}), do: :skip

  defp maybe_create_version(%WorkspaceDocument{} = doc) do
    content_hash = hash_content(doc.content_body || "")

    %WorkspaceDocumentVersion{}
    |> WorkspaceDocumentVersion.changeset(%{
      document_id: doc.id,
      version: doc.version,
      content_body: doc.content_body,
      blob_ref: doc.blob_ref,
      content_hash: content_hash,
      changed_by: doc.updated_by
    })
    |> Repo.insert!()

    # Prune old versions for drafts (keep last 5)
    if doc.lifecycle == :draft do
      prune_draft_versions(doc.id, 5)
    end
  end

  defp prune_draft_versions(document_id, keep) do
    versions_to_keep =
      from v in WorkspaceDocumentVersion,
        where: v.document_id == ^document_id,
        order_by: [desc: v.version],
        limit: ^keep,
        select: v.id

    from(v in WorkspaceDocumentVersion,
      where: v.document_id == ^document_id and v.id not in subquery(versions_to_keep)
    )
    |> Repo.delete_all()
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
