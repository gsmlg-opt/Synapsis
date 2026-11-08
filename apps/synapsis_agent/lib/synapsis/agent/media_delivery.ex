defmodule Synapsis.Agent.MediaDelivery do
  @moduledoc """
  Durable audio, image and video references using their original storage settings.

  An immutable runtime fact keeps the portable descriptor, original absolute
  media root, read bound and selected native invocation provenance. Public
  references contain only a version, session UUID and fresh delivery UUID; they
  never contain a host path. Reads use the exact fact and its original settings,
  independently of the current Agent configuration or Worker lifetime.

  Media publication, fact publication and native result settlement are separate
  operations, not an atomic transaction. A failure can leave unpublished media
  or an unreferenced fact; callers must not retry an uncertain synthesis. This
  module does not replay generation, own a process or manage media cleanup.
  Historical descriptor-only results have no delivery reference and cannot be
  resolved by guessing a media root. URLs serve complete media bodies; HTTP
  Range requests and seeking are outside the delivery contract.
  """

  alias Synapsis.Runtime.Store
  alias Synapsis.Workspace.Media

  @invocation_keys [:run_id, :invocation_id, :tool_call_id, :tool_name]
  @formats %{
    "mp3" => "audio/mpeg",
    "aac" => "audio/aac",
    "opus" => "audio/ogg",
    "wav" => "audio/wav",
    "flac" => "audio/flac",
    "pcm" => "application/octet-stream",
    "ogg" => "audio/ogg",
    "webm" => "audio/webm",
    "amr" => "audio/amr",
    "audio" => "application/octet-stream"
  }
  @image_formats %{"png" => "image/png", "jpeg" => "image/jpeg", "webp" => "image/webp"}
  @sha256 ~r/\A[a-f0-9]{64}\z/

  @doc "Publishes a fresh reference after audio has been durably stored."
  def publish(descriptor, session_id, invocation, opts),
    do: publish_media(:audio_delivery, descriptor, session_id, invocation, opts)

  @doc "Publishes a fresh reference after image bytes have been durably stored."
  def publish_image(descriptor, session_id, invocation, opts),
    do: publish_media(:image_delivery, descriptor, session_id, invocation, opts)

  @doc "Publishes a fresh reference after opaque video bytes have been durably stored."
  def publish_video(descriptor, session_id, invocation, opts),
    do: publish_media(:video_delivery, descriptor, session_id, invocation, opts)

  defp publish_media(kind, descriptor, session_id, invocation, opts) do
    with :ok <- validate_descriptor(kind, descriptor),
         true <- uuid?(session_id),
         {:ok, settings} <- settings(opts),
         {:ok, provenance} <- provenance(invocation) do
      id = Ecto.UUID.generate()

      fact = %{
        version: 1,
        descriptor: descriptor,
        root: settings.root,
        max_bytes: settings.max_bytes,
        invocation: provenance
      }

      case Store.put_fact(session_id, kind, id, fact) do
        :ok -> {:ok, %{"version" => 1, "session_id" => session_id, "id" => id}}
        _ -> {:error, :delivery_unavailable}
      end
    else
      false -> {:error, :invalid_delivery}
      {:error, _} = error -> error
    end
  end

  @doc "Reads and verifies audio using the immutable publication settings."
  def read(session_id, delivery_id), do: read_media(:audio_delivery, session_id, delivery_id)

  @doc "Reads and verifies an image using the immutable publication settings."
  def read_image(session_id, delivery_id),
    do: read_media(:image_delivery, session_id, delivery_id)

  @doc "Reads video using its original descriptor, MIME type and storage settings."
  def read_video(session_id, delivery_id),
    do: read_media(:video_delivery, session_id, delivery_id)

  defp read_media(kind, session_id, delivery_id) do
    if uuid?(session_id) and uuid?(delivery_id) do
      case Store.get_fact(session_id, kind, delivery_id) do
        {:ok, fact} -> read_fact(kind, fact)
        :not_found -> {:error, :delivery_not_found}
        _ -> {:error, :delivery_unavailable}
      end
    else
      {:error, :invalid_delivery}
    end
  end

  @doc "Builds the local HTTP URL from an exact versioned public reference."
  def url(reference), do: media_url("audio", reference)

  @doc "Builds an image HTTP URL from an exact versioned public reference."
  def image_url(reference), do: media_url("image", reference)

  @doc "Builds a video HTTP URL from an exact versioned public reference."
  def video_url(reference), do: media_url("video", reference)

  defp media_url(kind, %{"version" => 1, "session_id" => session_id, "id" => id} = reference)
       when map_size(reference) == 3 do
    if uuid?(session_id) and uuid?(id),
      do: {:ok, "/api/media/" <> kind <> "/" <> session_id <> "/" <> id},
      else: {:error, :invalid_delivery}
  end

  defp media_url(_, _), do: {:error, :invalid_delivery}

  defp read_fact(
         kind,
         %{
           version: 1,
           descriptor: descriptor,
           root: root,
           max_bytes: max_bytes,
           invocation: invocation
         } = fact
       )
       when map_size(fact) == 5 do
    with :ok <- validate_descriptor(kind, descriptor),
         {:ok, settings} <- settings(root: root, max_bytes: max_bytes),
         true <- settings.root === root,
         {:ok, ^invocation} <- provenance(invocation),
         {:ok, %{descriptor: ^descriptor} = media} <-
           read_bytes(kind, descriptor, root: root, max_bytes: max_bytes) do
      {:ok, media}
    else
      _ -> {:error, :delivery_unavailable}
    end
  end

  defp read_fact(_, _), do: {:error, :delivery_unavailable}

  defp read_bytes(:audio_delivery, descriptor, opts),
    do: Media.read_audio(descriptor["uri"], opts)

  defp read_bytes(:image_delivery, descriptor, opts),
    do: Media.read_image(descriptor["uri"], opts)

  defp read_bytes(:video_delivery, descriptor, opts), do: Media.read_video(descriptor, opts)

  defp validate_descriptor(:video_delivery, descriptor),
    do: Media.validate_video_descriptor(descriptor)

  defp validate_descriptor(
         kind,
         %{
           "uri" => uri,
           "sha256" => sha256,
           "byte_size" => byte_size,
           "mime_type" => mime_type,
           "format" => format
         } = descriptor
       )
       when map_size(descriptor) == 5 and is_binary(sha256) and is_integer(byte_size) and
              byte_size >= 0 do
    {media_kind, formats} =
      case kind do
        :audio_delivery -> {"audio", @formats}
        :image_delivery -> {"image", @image_formats}
      end

    if Regex.match?(@sha256, sha256) and Map.has_key?(formats, format) and
         Map.fetch!(formats, format) === mime_type and
         uri === "synapsis-media://" <> media_kind <> "/" <> sha256 <> "." <> format,
       do: :ok,
       else: {:error, :invalid_descriptor}
  end

  defp validate_descriptor(_, _), do: {:error, :invalid_descriptor}

  defp settings(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      root = Keyword.get(opts, :root)
      max_bytes = Keyword.get(opts, :max_bytes)

      if is_binary(root) and root != "" and String.valid?(root) and
           not String.contains?(root, <<0>>) and Path.type(root) == :absolute and
           is_integer(max_bytes) and max_bytes > 0,
         do: {:ok, %{root: Path.expand(root), max_bytes: max_bytes}},
         else: {:error, :invalid_options}
    else
      {:error, :invalid_options}
    end
  end

  defp settings(_), do: {:error, :invalid_options}

  defp provenance(invocation) when is_map(invocation) do
    selected = Map.take(invocation, @invocation_keys)

    if Enum.all?(@invocation_keys, fn key ->
         is_binary(selected[key]) and selected[key] != "" and String.valid?(selected[key])
       end),
       do: {:ok, selected},
       else: {:error, :invalid_invocation}
  end

  defp provenance(_), do: {:error, :invalid_invocation}

  defp uuid?(id) when is_binary(id), do: Ecto.UUID.cast(id) == {:ok, id}
  defp uuid?(_), do: false
end
