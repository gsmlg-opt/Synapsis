defmodule Synapsis.Workspace.BlobStore do
  @moduledoc """
  Behaviour for content-addressable blob storage.

  Small text documents (<64KB) store content inline in `content_body`.
  Larger content and binary attachments use this blob store.
  """

  @callback put(content :: binary()) :: {:ok, ref :: String.t()} | {:error, term()}
  @callback get(ref :: String.t()) :: {:ok, binary()} | {:error, :not_found}
  @callback delete(ref :: String.t()) :: :ok
  @callback exists?(ref :: String.t()) :: boolean()
  @callback path_for_ref(ref :: String.t()) :: String.t()

  @inline_threshold 64 * 1024

  @doc """
  Returns the inline content threshold in bytes (64KB).
  Content smaller than this should be stored inline in content_body.
  """
  @spec inline_threshold() :: non_neg_integer()
  def inline_threshold, do: @inline_threshold

  @doc """
  Determine if content should be stored inline or in blob storage.
  """
  @spec inline?(binary()) :: boolean()
  def inline?(content) when is_binary(content), do: byte_size(content) < @inline_threshold
end
