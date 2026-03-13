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
  """

  alias Synapsis.Workspace.{Resources, Search, BlobStore, Resource}

  @doc """
  Read a workspace resource by path or ID.

  Returns a uniform `%Workspace.Resource{}` struct.
  """
  @spec read(String.t()) :: {:ok, Resource.t()} | {:error, :not_found}
  def read(path_or_id) do
    result =
      if uuid?(path_or_id) do
        Resources.get_by_id(path_or_id)
      else
        Resources.get_by_path(path_or_id)
      end

    case result do
      {:ok, doc} ->
        doc = maybe_load_blob(doc)
        {:ok, Resource.from_document(doc)}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Write content to a workspace path.

  Creates a new document if the path doesn't exist, or updates the existing one.
  Version history is managed based on the document's lifecycle state.

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
    {content_body, blob_ref} = maybe_store_blob(content, opts)
    opts = if blob_ref, do: Map.put(opts, :blob_ref, blob_ref), else: opts

    case Resources.upsert(path, content_body, opts) do
      {:ok, doc} ->
        doc = if blob_ref, do: %{doc | blob_ref: blob_ref}, else: doc
        {:ok, Resource.from_document(doc)}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Soft-delete a workspace resource by path or ID.
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
        :ok

      {:error, _} = error ->
        error
    end
  end

  @doc """
  List workspace resources under a path prefix.

  Options:
    - `:depth` - max depth of nesting (nil for unlimited)
    - `:kind` - filter by document kind
    - `:sort` - :path (default), :recent, :name
    - `:limit` - max results (default 100)
  """
  @spec list(String.t(), keyword()) :: {:ok, [Resource.t()]}
  def list(path_prefix, opts \\ []) do
    docs = Resources.list(path_prefix, opts)
    {:ok, Enum.map(docs, &Resource.from_document/1)}
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

  # Private helpers

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
