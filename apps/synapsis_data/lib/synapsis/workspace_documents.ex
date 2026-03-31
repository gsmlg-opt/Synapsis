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

    escaped_prefix =
      prefix
      |> String.replace("~", "~~")
      |> String.replace("%", "~%")
      |> String.replace("_", "~_")

    query =
      from(d in WorkspaceDocument,
        where:
          fragment("? LIKE ? ESCAPE '~'", d.path, ^"#{escaped_prefix}%") and
            is_nil(d.deleted_at),
        limit: ^limit
      )

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
      from(d in WorkspaceDocument,
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
      )

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
  # Regex search (grep) and glob pattern matching
  # ---------------------------------------------------------------------------

  @doc """
  Search workspace document content using PostgreSQL POSIX regex.

  Returns a list of maps with `:path`, `:line`, and `:content` keys.

  Options:
    - `:path_prefix` - limit search to documents under this path prefix
    - `:limit` - max documents to search (default 50)
  """
  @spec grep(String.t(), keyword()) :: [%{path: String.t(), line: integer(), content: String.t()}]
  def grep(pattern, opts \\ []) do
    path_prefix = Keyword.get(opts, :path_prefix)
    limit = Keyword.get(opts, :limit, 50)

    query =
      from(d in WorkspaceDocument,
        where:
          is_nil(d.deleted_at) and
            not is_nil(d.content_body) and
            fragment("? ~ ?", d.content_body, ^pattern),
        select: %{path: d.path, content_body: d.content_body},
        limit: ^limit,
        order_by: [asc: d.path]
      )

    query = apply_path_prefix(query, path_prefix)

    Repo.all(query)
    |> Enum.flat_map(fn %{path: path, content_body: body} ->
      body
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _num} ->
        Regex.match?(~r/#{Regex.escape(pattern)}/, line)
      end)
      |> Enum.map(fn {line, num} ->
        %{path: path, line: num, content: line}
      end)
    end)
  rescue
    # If regex is invalid for Elixir but valid for Postgres, fall back to simple matching
    _e in [Regex.CompileError, ArgumentError] ->
      []
  end

  @doc """
  Match workspace document paths using glob-style patterns.

  Converts glob syntax (`*`, `**`, `?`) to SQL LIKE patterns.

  Options:
    - `:path_prefix` - limit search to documents under this path prefix
    - `:limit` - max results (default 100)
  """
  @spec glob(String.t(), keyword()) :: [%{path: String.t()}]
  def glob(pattern, opts \\ []) do
    path_prefix = Keyword.get(opts, :path_prefix)
    limit = Keyword.get(opts, :limit, 100)
    sql_pattern = glob_to_like(pattern)

    query =
      from(d in WorkspaceDocument,
        where:
          is_nil(d.deleted_at) and
            fragment("? LIKE ? ESCAPE '\\\\'", d.path, ^sql_pattern),
        select: %{path: d.path},
        order_by: [desc: d.updated_at],
        limit: ^limit
      )

    query = apply_path_prefix(query, path_prefix)

    Repo.all(query)
  end

  defp apply_path_prefix(query, nil), do: query

  defp apply_path_prefix(query, prefix) do
    escaped =
      prefix
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    prefix_pattern = if String.ends_with?(escaped, "/"), do: escaped <> "%", else: escaped <> "/%"
    where(query, [d], fragment("? LIKE ? ESCAPE '\\\\'", d.path, ^prefix_pattern))
  end

  @doc false
  def glob_to_like(pattern) do
    pattern
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
    |> String.replace("**", "†")
    |> String.replace("*", "%")
    |> String.replace("?", "_")
    |> String.replace("†", "%")
  end

  # ---------------------------------------------------------------------------
  # Version history
  # ---------------------------------------------------------------------------

  @doc "Insert a version snapshot."
  @spec insert_version(map()) ::
          {:ok, WorkspaceDocumentVersion.t()} | {:error, Ecto.Changeset.t()}
  def insert_version(attrs) do
    %WorkspaceDocumentVersion{}
    |> WorkspaceDocumentVersion.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Prune draft versions for a specific document, keeping only the most recent `keep` versions.
  """
  @spec prune_versions(String.t(), non_neg_integer()) :: {non_neg_integer(), nil}
  def prune_versions(document_id, keep) do
    versions_to_keep =
      from(v in WorkspaceDocumentVersion,
        where: v.document_id == ^document_id,
        order_by: [desc: v.version],
        limit: ^keep,
        select: v.id
      )

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
      from(v in WorkspaceDocumentVersion,
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
      )

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

  @doc """
  Find stale session scratch document IDs.
  Excludes promoted documents (lifecycle >= :shared) per WS-9.3.
  """
  @spec stale_session_scratch_ids(DateTime.t()) :: [String.t()]
  def stale_session_scratch_ids(cutoff) do
    from(d in WorkspaceDocument,
      left_join: s in Synapsis.Session,
      on: d.session_id == s.id,
      where:
        d.kind == :session_scratch and
          d.lifecycle in [:scratch, :draft] and
          ((is_nil(d.session_id) and d.updated_at < ^cutoff) or
             (not is_nil(d.session_id) and s.updated_at < ^cutoff)),
      select: d.id
    )
    |> Repo.all()
  end

  @doc "Hard-delete documents and their versions by IDs."
  @spec hard_delete_by_ids([String.t()]) :: non_neg_integer()
  def hard_delete_by_ids([]), do: 0

  def hard_delete_by_ids(ids) do
    Repo.transaction(fn ->
      # Delete versions first (FK constraint)
      from(v in WorkspaceDocumentVersion, where: v.document_id in ^ids)
      |> Repo.delete_all()

      {count, _} =
        from(d in WorkspaceDocument, where: d.id in ^ids)
        |> Repo.delete_all()

      count
    end)
    |> case do
      {:ok, count} -> count
      {:error, _} -> 0
    end
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
  # Soft-delete
  # ---------------------------------------------------------------------------

  @doc "Build and persist a soft-delete changeset for a document."
  @spec soft_delete(WorkspaceDocument.t()) ::
          {:ok, WorkspaceDocument.t()} | {:error, Ecto.Changeset.t()}
  def soft_delete(document) do
    document
    |> WorkspaceDocument.soft_delete_changeset()
    |> Repo.update()
  end

  # ---------------------------------------------------------------------------
  # Domain projection queries — Skills
  # ---------------------------------------------------------------------------

  @doc "List skills by scope, optionally filtered by project_id."
  @spec list_skills(String.t(), String.t() | nil, non_neg_integer()) :: [struct()]
  def list_skills(scope, project_id, limit) do
    query =
      from(s in Synapsis.Skill,
        where: s.scope == ^scope,
        limit: ^limit
      )

    query =
      if project_id do
        where(query, [s], s.project_id == ^project_id)
      else
        where(query, [s], is_nil(s.project_id))
      end

    Repo.all(query)
  end

  @doc "Find a single skill by scope, optional project_id, and name."
  @spec find_skill(String.t(), String.t() | nil, String.t()) :: struct() | nil
  def find_skill(scope, project_id, name) do
    query =
      from(s in Synapsis.Skill,
        where: s.scope == ^scope and s.name == ^name,
        limit: 1
      )

    query =
      if project_id do
        where(query, [s], s.project_id == ^project_id)
      else
        where(query, [s], is_nil(s.project_id))
      end

    Repo.one(query)
  end

  # ---------------------------------------------------------------------------
  # Domain projection queries — Memory entries
  # ---------------------------------------------------------------------------

  @doc "List memory entries by scope, optionally filtered by scope_id."
  @spec list_memory_entries(String.t(), String.t() | nil, non_neg_integer()) :: [struct()]
  def list_memory_entries(scope, scope_id, limit) do
    query =
      from(m in Synapsis.MemoryEntry,
        where: m.scope == ^scope,
        limit: ^limit
      )

    query =
      if scope_id do
        where(query, [m], m.scope_id == ^scope_id)
      else
        where(query, [m], is_nil(m.scope_id))
      end

    Repo.all(query)
  end

  @doc "Find a single memory entry by scope, optional scope_id, and key."
  @spec find_memory_entry(String.t(), String.t() | nil, String.t()) :: struct() | nil
  def find_memory_entry(scope, scope_id, key) do
    query =
      from(m in Synapsis.MemoryEntry,
        where: m.scope == ^scope and m.key == ^key,
        limit: 1
      )

    query =
      if scope_id do
        where(query, [m], m.scope_id == ^scope_id)
      else
        where(query, [m], is_nil(m.scope_id))
      end

    Repo.one(query)
  end

  # ---------------------------------------------------------------------------
  # Domain projection queries — Session todos
  # ---------------------------------------------------------------------------

  @doc "List todos for a session, ordered by sort_order and inserted_at."
  @spec list_todos_for_session(String.t()) :: [struct()]
  def list_todos_for_session(session_id) do
    from(t in Synapsis.SessionTodo,
      where: t.session_id == ^session_id,
      order_by: [asc: t.sort_order, asc: t.inserted_at]
    )
    |> Repo.all()
  end

  @doc "List session IDs for a project."
  @spec list_session_ids_for_project(String.t(), non_neg_integer()) :: [String.t()]
  def list_session_ids_for_project(project_id, limit) do
    from(s in Synapsis.Session,
      where: s.project_id == ^project_id,
      select: s.id,
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc "List all todos for a project in a single JOIN query, grouped by session_id."
  @spec list_todos_for_project(String.t(), non_neg_integer()) :: %{String.t() => [struct()]}
  def list_todos_for_project(project_id, limit) do
    from(t in Synapsis.SessionTodo,
      join: s in Synapsis.Session,
      on: t.session_id == s.id,
      where: s.project_id == ^project_id,
      order_by: [asc: t.sort_order, asc: t.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
    |> Enum.group_by(& &1.session_id)
  end

  # ---------------------------------------------------------------------------
  # Domain projection queries — Session lookup
  # ---------------------------------------------------------------------------

  @doc "Get the project_id for a session."
  @spec get_session_project_id(String.t()) :: String.t() | nil
  def get_session_project_id(session_id) do
    from(s in Synapsis.Session,
      where: s.id == ^session_id,
      select: s.project_id,
      limit: 1
    )
    |> Repo.one()
  end
end
