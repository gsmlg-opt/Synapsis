defmodule Synapsis.WorkspaceDocuments do
  @moduledoc """
  Data context for workspace documents.

  Encapsulates all Ecto queries and Repo operations for `workspace_documents`
  and `workspace_document_versions`. Other packages must use this module
  instead of accessing `Synapsis.Repo` directly.
  """

  import Ecto.Query

  alias Synapsis.Repo
  alias Synapsis.WorkspaceDocument
  alias Synapsis.WorkspaceDocumentVersion

  # ---------------------------------------------------------------------------
  # Document CRUD
  # ---------------------------------------------------------------------------

  @doc "Get a single document by ID, excluding soft-deleted."
  @spec get(String.t()) :: WorkspaceDocument.t() | nil
  def get(id) do
    case Repo.get(WorkspaceDocument, id) do
      %{deleted_at: deleted_at} = _doc when not is_nil(deleted_at) -> nil
      doc -> doc
    end
  end

  @doc "Get a single document by path, excluding soft-deleted."
  @spec get_by_path(String.t()) :: WorkspaceDocument.t() | nil
  def get_by_path(path) do
    from(d in WorkspaceDocument,
      where: d.path == ^path and is_nil(d.deleted_at)
    )
    |> Repo.one()
  end

  @doc "Insert a new document."
  @spec insert(Ecto.Changeset.t()) :: {:ok, WorkspaceDocument.t()} | {:error, Ecto.Changeset.t()}
  def insert(changeset) do
    Repo.insert(changeset)
  end

  @doc "Update a document."
  @spec update(Ecto.Changeset.t()) :: {:ok, WorkspaceDocument.t()} | {:error, Ecto.Changeset.t()}
  def update(changeset) do
    Repo.update(changeset)
  end

  @doc "Run a function inside a transaction."
  @spec transaction(fun()) :: {:ok, any()} | {:error, any()}
  def transaction(fun) do
    Repo.transaction(fun)
  end

  @doc "Rollback the current transaction."
  @spec rollback(any()) :: no_return()
  def rollback(reason) do
    Repo.rollback(reason)
  end

  # ---------------------------------------------------------------------------
  # Document listing
  # ---------------------------------------------------------------------------

  @doc "List active documents under a path prefix with optional filters."
  @spec list_by_prefix(String.t(), keyword()) :: [WorkspaceDocument.t()]
  def list_by_prefix(prefix, opts \\ []) do
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

  # ---------------------------------------------------------------------------
  # Full-text search
  # ---------------------------------------------------------------------------

  @doc "Full-text search over workspace documents using PostgreSQL tsvector."
  @spec search(String.t(), keyword()) :: [WorkspaceDocument.t()]
  def search(query_text, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    project_id = Keyword.get(opts, :project_id)
    kind = Keyword.get(opts, :kind)
    scope = Keyword.get(opts, :scope)

    query =
      from d in WorkspaceDocument,
        where:
          is_nil(d.deleted_at) and
            fragment(
              "? @@ websearch_to_tsquery('english', ?)",
              d.search_vector,
              ^query_text
            ),
        order_by:
          fragment(
            "ts_rank(?, websearch_to_tsquery('english', ?)) DESC",
            d.search_vector,
            ^query_text
          ),
        limit: ^limit

    query = if project_id, do: where(query, [d], d.project_id == ^project_id), else: query
    query = if kind, do: where(query, [d], d.kind == ^kind), else: query

    query =
      case scope do
        :global -> where(query, [d], is_nil(d.project_id))
        :project -> where(query, [d], not is_nil(d.project_id) and is_nil(d.session_id))
        :session -> where(query, [d], not is_nil(d.session_id))
        _ -> query
      end

    Repo.all(query)
  end

  # ---------------------------------------------------------------------------
  # Version history
  # ---------------------------------------------------------------------------

  @doc "Insert a version snapshot."
  @spec insert_version!(map()) :: WorkspaceDocumentVersion.t()
  def insert_version!(attrs) do
    %WorkspaceDocumentVersion{}
    |> WorkspaceDocumentVersion.changeset(attrs)
    |> Repo.insert!()
  end

  @doc """
  Prune draft versions for a specific document, keeping only the most recent `keep` versions.
  """
  @spec prune_versions(String.t(), non_neg_integer()) :: {non_neg_integer(), nil}
  def prune_versions(document_id, keep) do
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

  @doc """
  Prune draft versions for ALL draft documents in a single batch query using
  a window function. Returns count of deleted versions.
  """
  @spec prune_all_draft_versions(non_neg_integer()) :: non_neg_integer()
  def prune_all_draft_versions(keep) do
    ranked =
      from v in WorkspaceDocumentVersion,
        join: d in WorkspaceDocument,
        on: v.document_id == d.id,
        where: d.lifecycle == :draft and is_nil(d.deleted_at),
        select: %{
          id: v.id,
          row_num:
            fragment(
              "ROW_NUMBER() OVER (PARTITION BY ? ORDER BY ? DESC)",
              v.document_id,
              v.version
            )
        }

    ids_to_delete =
      from(r in subquery(ranked),
        where: r.row_num > ^keep,
        select: r.id
      )

    {count, _} =
      from(v in WorkspaceDocumentVersion,
        where: v.id in subquery(ids_to_delete)
      )
      |> Repo.delete_all()

    count
  end

  # ---------------------------------------------------------------------------
  # Bulk delete operations (for GC)
  # ---------------------------------------------------------------------------

  @doc "Find stale session scratch document IDs."
  @spec stale_session_scratch_ids(DateTime.t()) :: [String.t()]
  def stale_session_scratch_ids(cutoff) do
    stale_with_session =
      from d in WorkspaceDocument,
        join: s in Synapsis.Session,
        on: d.session_id == s.id,
        where: d.kind == :session_scratch and s.updated_at < ^cutoff,
        select: d.id

    stale_without_session =
      from d in WorkspaceDocument,
        where: d.kind == :session_scratch and is_nil(d.session_id) and d.updated_at < ^cutoff,
        select: d.id

    Repo.all(stale_with_session) ++ Repo.all(stale_without_session)
  end

  @doc "Hard-delete documents and their versions by IDs."
  @spec hard_delete_by_ids([String.t()]) :: non_neg_integer()
  def hard_delete_by_ids([]), do: 0

  def hard_delete_by_ids(ids) do
    # Delete versions first (FK constraint)
    from(v in WorkspaceDocumentVersion, where: v.document_id in ^ids)
    |> Repo.delete_all()

    {count, _} =
      from(d in WorkspaceDocument, where: d.id in ^ids)
      |> Repo.delete_all()

    count
  end

  @doc "Find IDs of expired soft-deleted documents."
  @spec expired_soft_deleted_ids(DateTime.t()) :: [String.t()]
  def expired_soft_deleted_ids(cutoff) do
    from(d in WorkspaceDocument,
      where: not is_nil(d.deleted_at) and d.deleted_at < ^cutoff,
      select: d.id
    )
    |> Repo.all()
  end

  @doc "Get all blob_refs referenced by documents."
  @spec referenced_doc_blob_refs() :: MapSet.t(String.t())
  def referenced_doc_blob_refs do
    from(d in WorkspaceDocument,
      where: not is_nil(d.blob_ref),
      select: d.blob_ref
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc "Get all blob_refs referenced by document versions."
  @spec referenced_version_blob_refs() :: MapSet.t(String.t())
  def referenced_version_blob_refs do
    from(v in WorkspaceDocumentVersion,
      where: not is_nil(v.blob_ref),
      select: v.blob_ref
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc "Get all draft document IDs (active, not deleted)."
  @spec draft_document_ids() :: [String.t()]
  def draft_document_ids do
    from(d in WorkspaceDocument,
      where: d.lifecycle == :draft and is_nil(d.deleted_at),
      select: d.id
    )
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Domain projection queries
  # ---------------------------------------------------------------------------

  @doc "Query domain schema records via Repo. Returns results or empty list if schema not loaded."
  @spec query_all(Ecto.Queryable.t()) :: [any()]
  def query_all(queryable) do
    Repo.all(queryable)
  end

  @doc "Query a single domain schema record via Repo."
  @spec query_one(Ecto.Queryable.t()) :: any() | nil
  def query_one(queryable) do
    Repo.one(queryable)
  end

  @doc "Get a record by ID from any schema."
  @spec get_record(module(), String.t()) :: any() | nil
  def get_record(schema, id) do
    Repo.get(schema, id)
  end
end
