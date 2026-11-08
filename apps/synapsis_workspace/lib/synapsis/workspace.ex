defmodule Synapsis.Workspace do
  @moduledoc """
  Public API for the shared workspace.

  The workspace is a database-backed, path-addressed shared storage layer
  where agents write work products and users browse/edit them.

  ## Functions

    * `read/1` — read content by path or id
    * `write/3` — create or update a document at a path
    * `delete/1` — soft-delete a document by path or id
    * `list/2` — list documents under a path prefix
    * `search/2` — full-text search across documents
    * `move/2` — rename/move a document to a new path
    * `stat/1` — get metadata without content
    * `exists?/1` — check if a path exists
  """

  require Logger
  alias Synapsis.Filesystem.Local
  alias Synapsis.WorkspaceDocuments
  alias Synapsis.Workspace.FileDocuments
  alias Synapsis.Workspace.{Resources, Search, BlobStore, Resource, PathResolver, Projection}

  @doc "Prepares captured file bytes without metadata mutation or publication."
  def read_file(path, args, opts, root \\ WorkspaceDocuments.root()) do
    WorkspaceDocuments.read_file(path, args, opts, root)
  end

  @doc """
  Persists bounded native file-domain operations and then publishes their changes.
  Call through ToolFiles for logical path, role and projection authorization.
  """
  def tool_files(action, arguments, author) do
    with :ok <- Local.validate(action, arguments) do
      WorkspaceDocuments.with_paths(tool_paths(action, arguments), fn scope ->
        WorkspaceDocuments.tool_files(action, arguments, author, scope)
        |> finish_files(scope)
      end)
    end
  end

  @doc "Source text operations with content, metadata and publication in one scope."
  def text_files(action, arguments, author, opts \\ [], root \\ WorkspaceDocuments.root()) do
    if is_map(arguments) and is_binary(arguments["path"]) and Keyword.keyword?(opts) do
      initial = %{root: root, io: Keyword.take(opts, [:deadline])}

      result =
        WorkspaceDocuments.with_paths([arguments["path"]], initial, fn scope ->
          WorkspaceDocuments.text_files(action, arguments, author, opts, scope)
          |> finish_files(scope)
        end)

      FileDocuments.source_outcome(initial.root, arguments["path"], result)
    else
      {:error, :invalid_input}
    end
  end

  @doc "Pins the Workspace root and holds a direct directory scope through domain rendering."
  def with_directory_entries(path, io_opts, callback, root \\ WorkspaceDocuments.root()) do
    initial = %{root: root, io: io_opts}
    WorkspaceDocuments.with_directory_entries(path, initial, callback)
  end

  defp finish_files({:ok, %{result: result, changes: changes}}, scope) do
    with :ok <- publish_tool_changes(changes, scope), do: {:ok, result}
  end

  defp finish_files({:error, reason, changes}, scope) do
    case publish_tool_changes(changes, scope) do
      :ok ->
        {:error, reason}

      {:error, publication_reason} ->
        {:error,
         {:unknown_outcome,
          %{operation: reason, publication: publication_reason, confirmed_changes: changes}}}
    end
  end

  defp finish_files(result, _scope), do: result

  defp publish_tool_changes(changes, scope) do
    Enum.reduce_while(changes, :ok, fn change, :ok ->
      case broadcast_change(
             change.path,
             change.action,
             change.resource_id,
             change.agent_id,
             scope
           ) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt,
           {:error,
            {:unknown_outcome,
             %{reason: :publication_failed, publication: reason, confirmed_changes: changes}}}}
      end
    end)
  end

  defp tool_paths(:file_move, args), do: [args["source"], args["destination"]]
  defp tool_paths(:multi_edit, args), do: Enum.map(args["edits"], & &1["path"])
  defp tool_paths(_, args), do: [Map.get(args, "path", ".")]

  @doc "Bounded ordinary index for authorized native file-domain enumeration."
  def tool_file_index(path, depth), do: Synapsis.WorkspaceDocuments.tool_index(path, depth)

  @doc "Full-content bounded search for authorized native file-domain enumeration."
  def tool_file_search(path, pattern), do: Synapsis.WorkspaceDocuments.tool_search(path, pattern)

  @doc """
  Read a workspace resource by path or ID.

  Returns a uniform `%Workspace.Resource{}` struct. First checks domain-backed
  projections (skills, memory, todos), then falls back to workspace_documents.
  """
  @spec read(String.t()) :: {:ok, Resource.t()} | {:error, :not_found}
  def read(path_or_id) do
    # Workspace paths are canonically leading-slash; anything else (UUID or the
    # file-backed md5 document id) is resolved by id.
    if is_binary(path_or_id) and String.starts_with?(path_or_id, "/") do
      read_by_path(path_or_id)
    else
      read_by_id(path_or_id)
    end
  end

  defp read_by_id(id) do
    case Resources.get_by_id(id) do
      {:ok, doc} ->
        doc = maybe_load_blob(doc)
        {:ok, Resource.from_document(doc)}

      {:error, _} = error ->
        error
    end
  end

  defp read_by_path(path) do
    # Try domain projection first, then workspace_documents
    case Projection.find_projected(path) do
      {:ok, resource} ->
        {:ok, resource}

      {:error, :not_found} ->
        case Resources.get_by_path(path) do
          {:ok, doc} ->
            doc = maybe_load_blob(doc)
            {:ok, Resource.from_document(doc)}

          {:error, _} = error ->
            error
        end
    end
  end

  @doc """
  Write content to a workspace path.

  Creates a new document if the path doesn't exist, or updates the existing one.
  Version history is managed based on the document's lifecycle state.

  Validates the path and rejects writes to domain-backed paths (skills, memory, todos).
  Broadcasts `{:workspace_changed, path, action}` via PubSub on success.

  Options:
    - `:author` - who is writing (agent_id or "user"), default "system"
    - `:metadata` - map of metadata
    - `:content_format` - :markdown (default), :yaml, :json, :text, :binary
    - `:visibility` - override default visibility
    - `:lifecycle` - override default lifecycle
    - `:kind` - override auto-detected kind
  """
  @spec write(String.t(), String.t() | binary(), map()) ::
          {:ok, Resource.t()} | {:error, term()}
  def write(path, content, opts \\ %{}) do
    with :ok <- validate_path(path),
         :ok <- reject_domain_path(path) do
      storage_path = PathResolver.normalize_path(path)

      WorkspaceDocuments.with_paths([storage_path], fn scope ->
        with {:ok, action} <- write_action(path, scope) do
          {content_body, blob_ref} = maybe_store_blob(content, opts)
          opts = if blob_ref, do: Map.put(opts, :blob_ref, blob_ref), else: opts

          with {:ok, doc} <- Resources.upsert(path, content_body, opts, scope) do
            doc = if blob_ref, do: %{doc | blob_ref: blob_ref}, else: doc
            # Preserve immediate blob content while its separate store remains unchanged.
            resource = doc |> maybe_load_blob() |> Resource.from_document()

            with :ok <-
                   publish_tool_changes(
                     [
                       %{path: path, action: action, resource_id: doc.id, agent_id: doc.agent_id}
                     ],
                     scope
                   ),
                 do: {:ok, resource}
          end
        end
      end)
    end
  end

  defp write_action(path, scope) do
    case Resources.get_by_path(path, scope) do
      {:ok, _} -> {:ok, :updated}
      {:error, :not_found} -> {:ok, :created}
      {:error, _} = error -> error
    end
  end

  @doc """
  Soft-delete a workspace resource by path or ID.

  Broadcasts `{:workspace_changed, path, :deleted}` via PubSub on success.
  """
  @spec delete(String.t()) :: :ok | {:error, :not_found}
  def delete(path_or_id) do
    initial = %{root: WorkspaceDocuments.root(), io: []}

    if is_binary(path_or_id) and String.starts_with?(path_or_id, "/") do
      delete_path(path_or_id, nil, initial)
    else
      # Candidate discovery precedes the exact pair. Never scan the root under
      # a child lease; the current ID is checked again before any effect.
      with {:ok, candidate} <- Resources.get_by_id(path_or_id, initial) do
        delete_path(candidate.path, path_or_id, initial)
      end
    end
  end

  defp delete_path(path, expected_id, initial) do
    path = PathResolver.normalize_path(path)

    WorkspaceDocuments.with_paths([path], initial, fn scope ->
      with {:ok, doc} <- Resources.get_by_path(path, scope),
           true <- is_nil(expected_id) or doc.id == expected_id,
           {:ok, _} <- Resources.soft_delete(doc, scope),
           :ok <-
             publish_tool_changes(
               [
                 %{path: doc.path, action: :deleted, resource_id: doc.id, agent_id: doc.agent_id}
               ],
               scope
             ) do
        :ok
      else
        false -> {:error, :not_found}
        error -> error
      end
    end)
  end

  @doc """
  List workspace resources under a path prefix.

  Merges results from domain-backed projections and workspace_documents.

  Options:
    - `:depth` - max depth of nesting (nil for unlimited)
    - `:kind` - filter by document kind
    - `:sort` - :path (default), :recent, :name
    - `:limit` - max results (default 100)
  """
  @spec list(String.t(), keyword()) :: {:ok, [Resource.t()]}
  def list(path_prefix, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    docs = Resources.list(path_prefix, opts)
    doc_resources = Enum.map(docs, &Resource.from_document/1)

    projected = Projection.list_projected(path_prefix, opts)

    sort = Keyword.get(opts, :sort, :path)

    merged =
      (doc_resources ++ projected)
      |> Enum.uniq_by(& &1.id)
      |> sort_resources(sort)
      |> Enum.take(limit)

    {:ok, merged}
  end

  @doc """
  Search workspace documents using full-text search.

  Options:
    - `:scope` - :global, :agent, or :session
    - `:agent_id` - filter by agent
    - `:kind` - filter by document kind
    - `:limit` - max results (default 20)
  """
  @spec search(String.t(), keyword()) :: {:ok, [Resource.t()]}
  def search(query, opts \\ []) do
    docs = Search.search(query, opts)
    {:ok, Enum.map(docs, &Resource.from_document/1)}
  end

  @doc """
  Move/rename a document from one path to another.

  Validates the target path and broadcasts workspace changes.
  """
  @spec move(String.t(), String.t()) :: {:ok, Resource.t()} | {:error, term()}
  def move(from_path, to_path) do
    with :ok <- validate_path(to_path),
         :ok <- reject_domain_path(to_path) do
      storage_paths = Enum.map([from_path, to_path], &PathResolver.normalize_path/1)

      WorkspaceDocuments.with_paths(storage_paths, fn scope ->
        with {:ok, doc} <- Resources.get_by_path(from_path, scope),
             {:ok, updated} <- Resources.move(doc, to_path, scope),
             :ok <-
               publish_tool_changes(
                 [
                   %{
                     path: from_path,
                     action: :deleted,
                     resource_id: doc.id,
                     agent_id: doc.agent_id
                   },
                   %{
                     path: to_path,
                     action: :created,
                     resource_id: doc.id,
                     agent_id: updated.agent_id
                   }
                 ],
                 scope
               ) do
          {:ok, Resource.from_document(updated)}
        end
      end)
    end
  end

  @doc """
  Get resource metadata without content. Faster than `read/1` for listings.
  """
  @spec stat(String.t()) :: {:ok, Resource.t()} | {:error, :not_found}
  def stat(path) do
    case Resources.get_by_path(path) do
      {:ok, doc} ->
        resource = Resource.from_document(doc)
        {:ok, %{resource | content: nil}}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Check if a path exists in the workspace.
  """
  @spec exists?(String.t()) :: boolean()
  def exists?(path) do
    case Resources.get_by_path(path) do
      {:ok, _} -> true
      {:error, :not_found} -> false
    end
  end

  # ---------------------------------------------------------------------------
  # Path validation (WS-4.1)
  # ---------------------------------------------------------------------------

  @max_path_depth 10
  @max_path_length 1024

  @doc """
  Validate a workspace path per WS-4.1 rules.
  """
  @spec validate_path(String.t()) :: :ok | {:error, String.t()}
  def validate_path(path) do
    path = PathResolver.normalize_path(path)

    cond do
      byte_size(path) > @max_path_length ->
        {:error, "path exceeds maximum length of #{@max_path_length} bytes"}

      not String.starts_with?(path, "/shared/") and
        not String.starts_with?(path, "/agents/") and
          not String.starts_with?(path, "/global/") ->
        {:error, "path must start with /shared/, /agents/, or /global/"}

      true ->
        segments = path |> String.trim_leading("/") |> String.split("/", trim: true)

        cond do
          length(segments) > @max_path_depth ->
            {:error, "path exceeds maximum depth of #{@max_path_depth} segments"}

          Enum.any?(segments, &(&1 == "." or &1 == "..")) ->
            {:error, "path must not contain . or .. segments"}

          Enum.any?(segments, &(&1 == "")) ->
            {:error, "path must not contain empty segments"}

          not Enum.all?(segments, &valid_segment?/1) ->
            {:error,
             "path segments must be lowercase alphanumeric, hyphens, underscores, or dots"}

          true ->
            :ok
        end
    end
  end

  defp valid_segment?(segment) do
    Regex.match?(~r/^[a-z0-9][a-z0-9._-]*$/, segment)
  end

  # ---------------------------------------------------------------------------
  # Domain-backed path rejection (WS-4.3)
  # ---------------------------------------------------------------------------

  defp reject_domain_path(path) do
    path = PathResolver.normalize_path(path)

    domain_patterns = [
      ~r{^/shared/skills/},
      ~r{^/agents/[^/]+/skills/},
      ~r{^/shared/memory/},
      ~r{^/agents/[^/]+/memory/},
      ~r{^/agents/[^/]+/sessions/[^/]+/todo\.md$}
    ]

    if Enum.any?(domain_patterns, &Regex.match?(&1, path)) do
      {:error, "cannot write to domain-backed path — use the domain context instead"}
    else
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # PubSub broadcasts (WS-16)
  # ---------------------------------------------------------------------------

  defp broadcast_change(path, action, resource_id, agent_id, scope) do
    message = {:workspace_changed, %{path: path, action: action, resource_id: resource_id}}

    topic =
      if agent_id do
        "workspace:agent:#{agent_id}"
      else
        "workspace:global"
      end

    with :ok <- Local.check_scope(scope.io) do
      Phoenix.PubSub.broadcast(Synapsis.PubSub, topic, message)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp sort_resources(resources, :recent),
    do: Enum.sort_by(resources, & &1.updated_at, {:desc, DateTime})

  defp sort_resources(resources, _),
    do: Enum.sort_by(resources, & &1.path)

  defp maybe_load_blob(%{content_body: nil, blob_ref: ref} = doc) when is_binary(ref) do
    blob_store = blob_store_module()

    case blob_store.get(ref) do
      {:ok, content} ->
        %{doc | content_body: content}

      {:error, reason} ->
        Logger.warning("blob_load_failed",
          blob_ref: ref,
          document_id: doc.id,
          reason: inspect(reason)
        )

        doc
    end
  end

  defp maybe_load_blob(doc), do: doc

  defp maybe_store_blob(content, _opts) when is_binary(content) do
    if BlobStore.inline?(content) do
      {content, nil}
    else
      blob_store = blob_store_module()

      case blob_store.put(content) do
        {:ok, ref} -> {nil, ref}
        {:error, _} -> {content, nil}
      end
    end
  end

  defp blob_store_module do
    Application.get_env(:synapsis_workspace, :blob_store, BlobStore.Local)
  end
end
