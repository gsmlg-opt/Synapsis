defmodule Synapsis.Workspace.BlobStore.Local do
  @moduledoc """
  Content-addressable local filesystem blob store.

  Stores blobs at `~/.config/synapsis/blobs/<aa>/<bb>/<hash>` where
  the hash is SHA-256 of the content.
  """
  @behaviour Synapsis.Workspace.BlobStore

  require Logger

  @default_root Path.expand("~/.config/synapsis/blobs")

  defp root_dir do
    Application.get_env(:synapsis_workspace, :blob_store_root, @default_root)
  end

  @impl true
  def put(content) when is_binary(content) do
    ref = hash(content)
    path = ref_to_path(ref)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, content) do
      {:ok, ref}
    end
  end

  @impl true
  def get(ref) when is_binary(ref) do
    with :ok <- validate_ref(ref) do
      path = ref_to_path(ref)

      case File.read(path) do
        {:ok, content} -> {:ok, content}
        {:error, :enoent} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def delete(ref) when is_binary(ref) do
    with :ok <- validate_ref(ref) do
      path = ref_to_path(ref)

      case File.rm(path) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("blob_delete_failed", ref: ref, reason: reason)
          :ok
      end
    end
  end

  @impl true
  def exists?(ref) when is_binary(ref) do
    match?(:ok, validate_ref(ref)) and ref |> ref_to_path() |> File.exists?()
  end

  @impl true
  @doc "Return the filesystem path for a given blob ref."
  @spec path_for_ref(String.t()) :: String.t()
  def path_for_ref(ref) when is_binary(ref) do
    :ok = validate_ref(ref)
    ref_to_path(ref)
  end

  # Validate that a blob ref is a valid SHA-256 hex string (prevents directory traversal).
  defp validate_ref(ref) when byte_size(ref) >= 5 do
    if Regex.match?(~r/^[a-f0-9]+$/, ref), do: :ok, else: {:error, :invalid_ref}
  end

  defp validate_ref(_), do: {:error, :invalid_ref}

  defp hash(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp ref_to_path(ref) do
    <<a::binary-size(2), b::binary-size(2), rest::binary>> = ref
    Path.join([root_dir(), a, b, rest])
  end
end
