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
  alias Synapsis.Filesystem.Local
  alias Synapsis.Workspace.FileDocuments
  alias Synapsis.WorkspaceDocument

  @doc "Workspace root for file-backed documents."
  def root, do: System.get_env("SYNAPSIS_WORKSPACE_ROOT") || File.cwd!()

  @doc "Reads captured bytes using one pinned trusted domain root, without metadata effects."
  def read_file(path, args, opts, root \\ root()) do
    FileDocuments.read_file(root, path, args, opts)
  end

  @doc "Pins the root and carries the validated store scope explicitly."
  def with_paths(paths, scope \\ nil, callback) do
    scope = domain_scope(scope)

    FileDocuments.with_paths(scope.root, paths, scope.io, fn io ->
      callback.(%{root: scope.root, io: io})
    end)
  end

  @doc "Carries a pinned directory result and its explicit original store scope."
  def with_directory_entries(path, scope \\ nil, callback) do
    scope = domain_scope(scope)

    FileDocuments.with_directory_entries(scope.root, path, scope.io, fn entries, io ->
      callback.(entries, %{root: scope.root, io: io})
    end)
  end

  @doc "Bounded file-tool operations without authorization or publication."
  def tool_files(action, arguments, author, scope \\ nil) do
    scope = domain_scope(scope)
    FileDocuments.tool_perform(scope.root, action, arguments, author, scope.io)
  end

  def text_files(action, arguments, author, opts \\ [], scope \\ nil) do
    scope = domain_scope(scope)

    FileDocuments.text_perform(
      scope.root,
      action,
      arguments,
      author,
      Keyword.merge(opts, scope.io)
    )
  end

  def tool_index(path, depth, scope \\ nil) do
    scope = domain_scope(scope)
    FileDocuments.tool_index(scope.root, path, depth, scope.io)
  end

  def tool_search(path, pattern, scope \\ nil) do
    scope = domain_scope(scope)
    FileDocuments.tool_search(scope.root, path, pattern, scope.io)
  end

  # ── document CRUD (FileDocuments-backed) ────────────────────────────────────

  def get_by_path(path, scope \\ nil) do
    scope = domain_scope(scope)

    case FileDocuments.get(scope.root, path, scope.io) do
      {:ok, map} -> to_struct(map)
      {:error, :not_found} -> nil
      {:error, reason} -> raise "workspace document read failed: #{inspect(reason)}"
    end
  end

  @doc "Finds an ID before acquiring its exact pair; a nested child scope cannot discover IDs."
  def get(id, scope \\ nil) do
    scope = domain_scope(scope)

    if Keyword.has_key?(scope.io, :lease) do
      raise "workspace document ID lookup requires an initial discovery scope"
    end

    case Enum.find(all_docs(scope), &(&1.id == id)) do
      nil ->
        nil

      doc ->
        with_paths([doc.path], scope, fn current_scope ->
          case get_by_path(doc.path, current_scope) do
            %WorkspaceDocument{id: ^id} = current -> current
            _ -> nil
          end
        end)
    end
  end

  def list_by_prefix(prefix, opts \\ []) do
    scope = domain_scope(nil)
    pattern = String.trim_leading(prefix, "/") <> "**"

    scope.root
    |> FileDocuments.list([pattern: pattern], scope.io)
    |> Enum.map(&to_struct/1)
    |> apply_depth(opts)
  end

  def insert(attrs_or_changeset, scope \\ nil)

  def insert(%Ecto.Changeset{} = changeset, scope),
    do: put_changeset(changeset, domain_scope(scope))

  def insert(attrs, scope) when is_map(attrs), do: put_map(attrs, domain_scope(scope))

  def update(%Ecto.Changeset{} = changeset, scope \\ nil),
    do: put_changeset(changeset, domain_scope(scope))

  def soft_delete(%WorkspaceDocument{path: path} = doc, scope \\ nil) do
    scope = domain_scope(scope)

    case FileDocuments.delete(scope.root, path, scope.io) do
      :ok -> {:ok, doc}
      error -> error
    end
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
    scope = domain_scope(nil)

    all_docs(scope)
    # all_docs/0 is metadata-only; load content per doc before substring matching.
    |> Enum.map(&(get_by_path(&1.path, scope) || &1))
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
    scope = domain_scope(nil)

    case Local.directory_snapshot(
           scope.root,
           ".",
           %{pattern: String.trim_leading(pattern, "/")},
           scope.io
         ) do
      {:ok, %{entries: entries}} ->
        Enum.map(entries, fn entry -> %{path: "/" <> entry.path} end)

      {:error, reason} ->
        raise "workspace glob failed: #{inspect(reason)}"
    end
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

  defp domain_scope(nil), do: %{root: root(), io: []}
  defp domain_scope(%{root: root, io: io}), do: %{root: root, io: io}

  defp all_docs, do: all_docs(domain_scope(nil))

  defp all_docs(scope),
    do: scope.root |> FileDocuments.list([], scope.io) |> Enum.map(&to_struct/1)

  defp put_changeset(%Ecto.Changeset{} = changeset, scope) do
    if changeset.valid?,
      do: put_map(Ecto.Changeset.apply_changes(changeset), scope),
      else: {:error, changeset}
  end

  defp put_map(attrs, scope) do
    map = if is_struct(attrs), do: Map.from_struct(attrs), else: attrs
    string_keyed = Map.new(map, fn {k, v} -> {to_string(k), v} end)

    case FileDocuments.put(scope.root, string_keyed, scope.io) do
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
