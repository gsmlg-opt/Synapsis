defmodule Synapsis.Workspace.FileDocuments do
  @moduledoc """
  File-backed workspace document store.

  Documents are stored as files on disk under the workspace root. The document's
  `:path` field is the relative path from the workspace root. Metadata (kind,
  visibility, lifecycle, etc.) is stored in a JSON sidecar at
  `<workspace_root>/.synapsis/meta/<encoded_path>.json`.

  This is the file-system replacement for the DB-backed `WorkspaceDocuments`
  context. The existing Ecto context still works until the C4 cutover.
  """

  require Logger

  @meta_dir ".synapsis/meta"
  @default_format "markdown"

  @type document :: %{
          id: String.t(),
          path: String.t(),
          kind: String.t(),
          visibility: String.t(),
          lifecycle: String.t(),
          content_format: String.t(),
          content_body: String.t(),
          metadata: map(),
          version: non_neg_integer(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "Get a document by path within a workspace root."
  @spec get(String.t(), String.t()) :: {:ok, document()} | {:error, :not_found}
  def get(workspace_root, path) do
    full_path = Path.join(workspace_root, path)

    case File.read(full_path) do
      {:ok, content} ->
        meta = read_meta(workspace_root, path)

        {:ok,
         Map.merge(meta, %{
           id: meta[:id] || path_id(path),
           path: path,
           content_body: content,
           content_format: meta[:content_format] || infer_format(path)
         })}

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        Logger.warning("file_documents_read_error", path: full_path, reason: inspect(reason))
        {:error, :not_found}
    end
  end

  @doc "List all documents in a workspace root (shallow scan)."
  @spec list(String.t(), keyword()) :: [document()]
  def list(workspace_root, opts \\ []) do
    pattern = Keyword.get(opts, :pattern, "**/*")
    meta_prefix = Path.join(workspace_root, @meta_dir)

    workspace_root
    |> Path.join(pattern)
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(&String.starts_with?(&1, meta_prefix))
    |> Enum.map(fn abs_path ->
      # Normalize to the leading-slash path so meta lookup and id match put/get.
      path = "/" <> Path.relative_to(abs_path, workspace_root)
      meta = read_meta(workspace_root, path)

      Map.merge(meta, %{
        id: meta[:id] || path_id(path),
        path: path,
        content_format: meta[:content_format] || infer_format(path)
      })
    end)
  end

  @doc "Write a document to disk and persist its metadata sidecar."
  @spec put(String.t(), map()) :: {:ok, document()} | {:error, term()}
  def put(workspace_root, attrs) do
    path = attrs[:path] || attrs["path"]

    if is_nil(path) do
      {:error, :missing_path}
    else
      full_path = Path.join(workspace_root, path)
      File.mkdir_p!(Path.dirname(full_path))

      content = attrs[:content_body] || attrs["content_body"] || ""

      case File.write(full_path, content) do
        :ok ->
          now = DateTime.utc_now()

          existing_meta = read_meta(workspace_root, path)

          meta =
            Map.merge(existing_meta, %{
              id: attrs[:id] || attrs["id"] || existing_meta[:id] || path_id(path),
              path: path,
              kind: attrs[:kind] || attrs["kind"] || existing_meta[:kind] || "document",
              visibility:
                attrs[:visibility] || attrs["visibility"] || existing_meta[:visibility] ||
                  "private",
              lifecycle:
                attrs[:lifecycle] || attrs["lifecycle"] || existing_meta[:lifecycle] || "draft",
              content_format:
                attrs[:content_format] || attrs["content_format"] ||
                  existing_meta[:content_format] || infer_format(path),
              metadata: attrs[:metadata] || attrs["metadata"] || existing_meta[:metadata] || %{},
              version: (existing_meta[:version] || 0) + 1,
              inserted_at: existing_meta[:inserted_at] || now,
              updated_at: now
            })

          write_meta(workspace_root, path, meta)
          {:ok, Map.put(meta, :content_body, content)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Delete a document and its metadata sidecar."
  @spec delete(String.t(), String.t()) :: :ok
  def delete(workspace_root, path) do
    full_path = Path.join(workspace_root, path)
    File.rm(full_path)
    File.rm(meta_path(workspace_root, path))
    :ok
  end

  # --- Private ---

  defp read_meta(workspace_root, path) do
    mp = meta_path(workspace_root, path)

    case File.read(mp) do
      {:ok, json} ->
        case Jason.decode(json, keys: :atoms) do
          {:ok, map} ->
            map
            |> atomize_times(:inserted_at)
            |> atomize_times(:updated_at)

          _ ->
            %{}
        end

      _ ->
        %{}
    end
  end

  defp write_meta(workspace_root, path, meta) do
    mp = meta_path(workspace_root, path)
    File.mkdir_p!(Path.dirname(mp))

    serializable =
      Map.new(meta, fn
        {k, %DateTime{} = dt} -> {k, DateTime.to_iso8601(dt)}
        {k, v} -> {k, v}
      end)

    File.write!(mp, Jason.encode!(serializable, pretty: true))
  end

  defp meta_path(workspace_root, path) do
    encoded = String.replace(path, "/", "__")
    Path.join([workspace_root, @meta_dir, "#{encoded}.json"])
  end

  defp path_id(path), do: :crypto.hash(:md5, path) |> Base.encode16(case: :lower)

  defp infer_format(path) do
    case Path.extname(path) do
      ".md" -> "markdown"
      ".json" -> "json"
      ".yaml" -> "yaml"
      ".yml" -> "yaml"
      ".txt" -> "text"
      _ -> @default_format
    end
  end

  defp atomize_times(map, key) do
    case Map.get(map, key) do
      nil ->
        map

      str when is_binary(str) ->
        case DateTime.from_iso8601(str) do
          {:ok, dt, _} -> Map.put(map, key, dt)
          _ -> map
        end

      _ ->
        map
    end
  end
end
