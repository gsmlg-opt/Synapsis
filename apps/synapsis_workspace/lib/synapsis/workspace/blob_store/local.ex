defmodule Synapsis.Workspace.BlobStore.Local do
  @moduledoc """
  Content-addressable local filesystem blob store.

  Stores blobs at `~/.config/synapsis/blobs/<aa>/<bb>/<hash>` where
  the hash is SHA-256 of the content.
  """
  @behaviour Synapsis.Workspace.BlobStore

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
    path = ref_to_path(ref)

    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete(ref) when is_binary(ref) do
    path = ref_to_path(ref)
    File.rm(path)
    :ok
  end

  @impl true
  def exists?(ref) when is_binary(ref) do
    ref |> ref_to_path() |> File.exists?()
  end

  defp hash(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp ref_to_path(ref) do
    <<a::binary-size(2), b::binary-size(2), rest::binary>> = ref
    Path.join([root_dir(), a, b, rest])
  end
end
