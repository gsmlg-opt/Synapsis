defmodule Synapsis.WorkspaceDocuments do
  @moduledoc """
  Workspace document context — C4 file-backed facade.

  ADR-006 C4: workspace documents are plain files (see `FileDocuments`), not a
  Postgres table. This module preserves the context API the rest of the app
  expects, delegating document CRUD to `FileDocuments` (rooted at the workspace
  cwd) and the cross-cutting projections (skills, memory, todos) to their own
  backends (`Skills`, `Memory`, session-scoped Concord values).

  Version history and blob-ref GC were Postgres-specific; in the file model they
  degrade to no-ops (files are the durable form). Full-text search degrades to a
  substring/line scan.
  """
  alias Synapsis.Workspace.FileDocuments
  alias Synapsis.WorkspaceDocument

  @doc "Workspace root for file-backed documents."
  def root, do: System.get_env("SYNAPSIS_WORKSPACE_ROOT") || File.cwd!()

  # ── document CRUD (FileDocuments-backed) ────────────────────────────────────

  def get_by_path(path) do
    case FileDocuments.get(root(), path) do
      {:ok, map} -> to_struct(map)
      _ -> nil
    end
  end

  def get(id) do
    Enum.find(all_docs(), &(&1.id == id))
  end

  def list_by_prefix(prefix, opts \\ []) do
    pattern = String.trim_leading(prefix, "/") <> "**"
    root() |> FileDocuments.list(pattern: pattern) |> Enum.map(&to_struct/1) |> apply_depth(opts)
  end

  def insert(%Ecto.Changeset{} = changeset), do: put_changeset(changeset)
  def insert(attrs) when is_map(attrs), do: put_map(attrs)

  def update(%Ecto.Changeset{} = changeset), do: put_changeset(changeset)

  def soft_delete(%WorkspaceDocument{path: path} = doc) do
    FileDocuments.delete(root(), path)
    {:ok, doc}
  end

  # ── transactions (no real txn over files) ───────────────────────────────────

  def transaction(fun) when is_function(fun, 0) do
    {:ok, fun.()}
  catch
    {:workspace_rollback, value} -> {:error, value}
  end

  def rollback(value), do: throw({:workspace_rollback, value})

  # ── search / grep / glob (filesystem scan) ──────────────────────────────────

  def search(query_text, _opts \\ []) do
    q = String.downcase(query_text)

    all_docs()
    |> Enum.filter(&String.contains?(String.downcase(&1.content_body || ""), q))
  end

  def grep(pattern, _opts \\ []) do
    regex = compile_regex(pattern)

    for doc <- all_docs(),
        {line, idx} <- Enum.with_index(String.split(doc.content_body || "", "\n"), 1),
        regex && Regex.match?(regex, line) do
      %{path: doc.path, line: idx, content: line}
    end
  end

  def glob(pattern, _opts \\ []) do
    Path.wildcard(Path.join(root(), pattern))
    |> Enum.map(fn abs -> %{path: "/" <> Path.relative_to(abs, root())} end)
  end

  # ── version history + blob GC (no-ops in the file model) ────────────────────

  def insert_version(_attrs), do: {:ok, %{}}
  def prune_versions(_doc_id, _keep), do: :ok
  def prune_all_draft_versions(_keep), do: :ok
  def stale_session_scratch_ids(_cutoff), do: []
  def expired_soft_deleted_ids(_cutoff), do: []
  def hard_delete_by_ids(_ids), do: :ok
  def referenced_doc_blob_refs, do: MapSet.new()
  def referenced_version_blob_refs, do: MapSet.new()

  # ── cross-cutting projections (delegate to real backends) ───────────────────

  def list_skills(_scope, _agent_id, limit),
    do: Enum.take(safe(Synapsis.Skills, :list, []), limit)

  def find_skill(_scope, _agent_id, name),
    do: Enum.find(safe(Synapsis.Skills, :list, []), &(&1.name == name))

  def list_semantic_memories(_scope, scope_id, limit) do
    safe(Synapsis.Memory, :list_semantic, [], [[scope_id: scope_id, limit: limit]])
  end

  def find_semantic_memory(_scope, scope_id, _key) do
    case list_semantic_memories(nil, scope_id, 50) do
      [memory | _] when is_map(memory) -> memory
      _ -> nil
    end
  end

  def list_todos_for_session(session_id) do
    Synapsis.Session.Store.get_value(session_id, "todos", [])
  end

  def list_todos_for_agent(_agent_id, _limit), do: []

  def get_session_agent_id(session_id) do
    case Synapsis.Session.Store.get_meta(session_id) do
      {:ok, meta} -> meta[:agent]
      _ -> nil
    end
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp all_docs, do: root() |> FileDocuments.list([]) |> Enum.map(&to_struct/1)

  defp put_changeset(%Ecto.Changeset{} = changeset) do
    if changeset.valid?,
      do: put_map(Ecto.Changeset.apply_changes(changeset)),
      else: {:error, changeset}
  end

  defp put_map(attrs) do
    map = if is_struct(attrs), do: Map.from_struct(attrs), else: attrs
    string_keyed = Map.new(map, fn {k, v} -> {to_string(k), v} end)

    case FileDocuments.put(root(), string_keyed) do
      {:ok, doc} -> {:ok, to_struct(doc)}
      other -> other
    end
  end

  defp to_struct(map) when is_map(map) do
    fields = Map.new(map, fn {k, v} -> {to_existing_atom(k), v} end)
    struct(WorkspaceDocument, Map.take(fields, workspace_document_fields()))
  end

  defp workspace_document_fields,
    do: WorkspaceDocument.__schema__(:fields)

  defp to_existing_atom(k) when is_atom(k), do: k

  defp to_existing_atom(k) when is_binary(k) do
    String.to_existing_atom(k)
  rescue
    _ -> :__unknown__
  end

  defp apply_depth(docs, _opts), do: docs

  defp compile_regex(pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} -> regex
      _ -> nil
    end
  end

  defp safe(mod, fun, default, args \\ []) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, length(args)) do
      apply(mod, fun, args)
    else
      default
    end
  end
end
