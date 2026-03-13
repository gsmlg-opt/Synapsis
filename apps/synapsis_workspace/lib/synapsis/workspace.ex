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

  alias Synapsis.Workspace.{Resources, Search, BlobStore, Resource, PathResolver, Projection}

  @doc """
  Read a workspace resource by path or ID.

  Returns a uniform `%Workspace.Resource{}` struct. First checks domain-backed
  projections (skills, memory, todos), then falls back to workspace_documents.
  """
  @spec read(String.t()) :: {:ok, Resource.t()} | {:error, :not_found}
  def read(path_or_id) do
    if uuid?(path_or_id) do
      read_by_id(path_or_id)
    else
      read_by_path(path_or_id)
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
      is_new = match?({:error, :not_found}, Resources.get_by_path(path))
      {content_body, blob_ref} = maybe_store_blob(content, opts)
      opts = if blob_ref, do: Map.put(opts, :blob_ref, blob_ref), else: opts

      case Resources.upsert(path, content_body, opts) do
        {:ok, doc} ->
          doc = if blob_ref, do: %{doc | blob_ref: blob_ref}, else: doc
          resource = Resource.from_document(doc)
          action = if is_new, do: :created, else: :updated
          broadcast_change(path, action, doc.id, doc.project_id)
          {:ok, resource}

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  Soft-delete a workspace resource by path or ID.

  Broadcasts `{:workspace_changed, path, :deleted}` via PubSub on success.
  """
  @spec delete(String.t()) :: :ok | {:error, :not_found}
  def delete(path_or_id) do
    result =
      if uuid?(path_or_id) do
        Resources.get_by_id(path_or_id)
      else
        Resources.get_by_path(path_or_id)
      end

    case result do
      {:ok, doc} ->
        {:ok, _} = Resources.soft_delete(doc)
        broadcast_change(doc.path, :deleted, doc.id, doc.project_id)
        :ok

      {:error, _} = error ->
        error
    end
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

    merged =
      (doc_resources ++ projected)
      |> Enum.uniq_by(& &1.id)
      |> Enum.take(limit)

    {:ok, merged}
  end

  @doc """
  Search workspace documents using full-text search.

  Options:
    - `:scope` - :global, :project, or :session
    - `:project_id` - filter by project
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
         :ok <- reject_domain_path(to_path),
         {:ok, doc} <- Resources.get_by_path(from_path) do
      case Resources.move(doc, to_path) do
        {:ok, updated} ->
          resource = Resource.from_document(updated)
          broadcast_change(from_path, :deleted, doc.id, doc.project_id)
          broadcast_change(to_path, :created, doc.id, updated.project_id)
          {:ok, resource}

        {:error, _} = error ->
          error
      end
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
          not String.starts_with?(path, "/projects/") ->
        {:error, "path must start with /shared/ or /projects/"}

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
            {:error, "path segments must be lowercase alphanumeric, hyphens, underscores, or dots"}

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
      ~r{^/projects/[^/]+/skills/},
      ~r{^/shared/memory/},
      ~r{^/projects/[^/]+/memory/},
      ~r{^/projects/[^/]+/sessions/[^/]+/todo\.md$}
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

  defp broadcast_change(path, action, resource_id, project_id) do
    message = {:workspace_changed, %{path: path, action: action, resource_id: resource_id}}

    topic =
      if project_id do
        "workspace:#{project_id}"
      else
        "workspace:global"
      end

    Phoenix.PubSub.broadcast(Synapsis.PubSub, topic, message)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp uuid?(string) do
    case Ecto.UUID.cast(string) do
      {:ok, _} -> true
      :error -> false
    end
  end

  defp maybe_load_blob(%{content_body: nil, blob_ref: ref} = doc) when is_binary(ref) do
    blob_store = blob_store_module()

    case blob_store.get(ref) do
      {:ok, content} -> %{doc | content_body: content}
      {:error, _} -> doc
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
