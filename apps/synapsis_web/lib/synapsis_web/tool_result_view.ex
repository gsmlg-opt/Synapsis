defmodule SynapsisWeb.ToolResultView do
  @moduledoc "Display-only presentation of checked native tool-result projections."

  alias Synapsis.Agent.{DiffsDelivery, MediaDelivery}
  alias Synapsis.Agent.Tools.ResultProjection
  alias Synapsis.Part.ToolResult

  @image_mimes ~w(image/png image/jpeg image/gif image/webp)
  @audio_mimes %{
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
  @sidecars ~w(structured artifacts details progress pagination)

  @spec present(ToolResult.t()) :: map()
  def present(%ToolResult{projection: nil, content: content, is_error: is_error})
      when is_binary(content) and is_boolean(is_error) do
    %{blocks: [%{type: "text", text: content}], sidecars: [], error: nil, isError: is_error}
  end

  def present(%ToolResult{} = part) do
    case ResultProjection.from_part(part) do
      {:ok, %{"result" => result}} -> present_result(result)
      {:error, _} -> display_error(part.is_error, "Tool result cannot be displayed")
    end
  end

  defp present_result(result) do
    case public_error(result["error"]) do
      {:ok, error} ->
        %{
          blocks:
            content_blocks(result) ++
              audio_delivery_blocks(result) ++ diffs_delivery_blocks(result),
          sidecars: sidecars(result),
          error: error,
          isError: result["is_error"]
        }

      :error ->
        display_error(result["is_error"], "Tool result error cannot be displayed")
    end
  end

  defp public_error(nil), do: {:ok, nil}

  defp public_error(%{"class" => class, "message" => message} = error)
       when is_binary(class) and is_binary(message) do
    {:ok, %{class: class, message: message, details: error["details"]}}
  end

  defp public_error(_), do: :error

  defp display_error(is_error, message) do
    %{
      blocks: [],
      sidecars: [],
      error: nil,
      isError: is_error,
      displayError: %{class: "malformed_result", message: message}
    }
  end

  defp content_blocks(%{"content" => content}) when is_binary(content),
    do: [%{type: "text", text: content}]

  defp content_blocks(%{"content" => content}) when is_list(content),
    do: Enum.map(content, &content_block/1)

  defp content_blocks(%{"content" => content}),
    do: [%{type: "json", label: "Content", value: content}]

  defp content_blocks(_), do: []

  # Delivery URLs are derived from the public reference only. Presentation never
  # reads media, resolves storage roots or changes the persisted/provider result.
  defp audio_delivery_blocks(%{"details" => %{"mediaDescriptor" => descriptor} = details})
       when is_map(descriptor) do
    case audio_delivery(descriptor, details["mediaDelivery"]) do
      {:ok, block} ->
        [block]

      :error ->
        [
          %{
            type: "reference",
            kind: "audio-delivery-unavailable",
            label: "Audio delivery unavailable",
            value: media_metadata(descriptor)
          }
        ]
    end
  end

  defp audio_delivery_blocks(_), do: []

  # Diffs history carries receipts, not a request to resolve or regenerate bytes.
  # Keep links display-only and derive downloads from the exact public reference.
  defp diffs_delivery_blocks(%{"details" => %{"changed" => true, "mode" => mode} = details})
       when mode in ~w(view file image both) do
    viewer = if mode in ~w(view both), do: diffs_viewer_link(details), else: []
    file = if mode in ~w(file image both), do: diffs_file_link(details), else: []
    viewer ++ file
  end

  defp diffs_delivery_blocks(_), do: []

  defp diffs_viewer_link(%{
         "artifactId" => id,
         "viewerPath" => path,
         "viewerUrl" => url,
         "expiresAt" => expiry
       })
       when is_binary(id) and is_binary(path) and is_binary(url) do
    uri = URI.parse(url)

    if String.match?(id, ~r/\A[a-f0-9]{20}\z/) and
         String.match?(path, ~r/\A\/plugins\/diffs\/view\/[a-f0-9]{20}\/[a-f0-9]{48}\z/) and
         String.starts_with?(path, "/plugins/diffs/view/" <> id <> "/") and
         uri.scheme in ~w(http https) and is_binary(uri.host) and uri.host != "" and
         is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) and
         is_binary(uri.path) and String.ends_with?(uri.path, path) and iso_expiry?(expiry) do
      [
        %{
          type: "link",
          kind: "diffs-viewer",
          label: "Open diff viewer",
          href: url,
          expiresAt: expiry
        }
      ]
    else
      []
    end
  end

  defp diffs_viewer_link(_), do: []

  defp diffs_file_link(%{
         "fileDelivery" => reference,
         "fileFormat" => format,
         "fileBytes" => bytes,
         "fileExpiresAt" => expiry
       })
       when format in ~w(png pdf) and is_integer(bytes) and bytes >= 0 do
    with true <- iso_expiry?(expiry),
         {:ok, href} <- DiffsDelivery.file_url(reference) do
      [
        %{
          type: "link",
          kind: "diffs-file",
          label: "Download " <> String.upcase(format),
          href: href,
          filename: "preview." <> format,
          mediaType: if(format == "pdf", do: "application/pdf", else: "image/png"),
          bytes: bytes,
          expiresAt: expiry
        }
      ]
    else
      _ -> []
    end
  end

  defp diffs_file_link(_), do: []

  defp iso_expiry?(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _, _} -> true
      {:error, _} -> false
    end
  end

  defp iso_expiry?(_), do: false

  @doc "Builds the checked public audio display shared by messages and tool results."
  def audio_delivery(descriptor, reference) do
    with {:ok, format, mime} <- audio_descriptor(descriptor),
         {:ok, src} <- MediaDelivery.url(reference) do
      {:ok, %{type: "audio", src: src, mediaType: mime, filename: "audio." <> format}}
    else
      _ -> :error
    end
  end

  defp audio_descriptor(
         %{
           "uri" => uri,
           "sha256" => sha256,
           "byte_size" => size,
           "mime_type" => mime,
           "format" => format
         } = descriptor
       )
       when map_size(descriptor) == 5 and is_binary(sha256) and is_integer(size) and size >= 0 and
              is_map_key(@audio_mimes, format) do
    if mime == @audio_mimes[format] and String.match?(sha256, ~r/\A[a-f0-9]{64}\z/) and
         uri == "synapsis-media://audio/" <> sha256 <> "." <> format,
       do: {:ok, format, mime},
       else: :error
  end

  defp audio_descriptor(_), do: :error

  defp content_block(%{"type" => "text", "text" => text}) when is_binary(text),
    do: %{type: "text", text: text}

  defp content_block(%{"type" => "image"} = block) do
    case inline_image(block) do
      {:ok, mime, src} ->
        image = %{type: "image", src: src, mediaType: mime, alt: "Tool result image"}
        metadata = image_metadata(block)
        if metadata == %{}, do: image, else: Map.put(image, :metadata, metadata)

      :error ->
        if image_reference?(block),
          do: reference(block, "image", "Image reference"),
          else: unsupported(block, "image", "Unsupported image representation")
    end
  end

  defp content_block(%{"type" => kind} = block)
       when kind in ~w(audio resource resource_link) do
    label =
      case kind do
        "audio" -> "Audio metadata"
        "resource" -> "Resource metadata"
        "resource_link" -> "Resource link"
      end

    reference(block, kind, label)
  end

  defp content_block(%{"type" => kind} = block) when is_binary(kind),
    do: unsupported(block, kind, "Unsupported content: " <> kind)

  defp content_block(block), do: unsupported(block, "unknown", "Unsupported content")

  defp reference(block, kind, label) do
    %{
      type: "reference",
      kind: kind,
      label: label,
      uri: reference_field(block, ~w(uri url image_url)),
      text: reference_field(block, ~w(text)),
      value: media_metadata(block)
    }
  end

  defp reference_field(block, keys) do
    Enum.find_value([block, block["data"], block["resource"], block["source"]], fn
      value when is_map(value) ->
        Enum.find_value(keys, fn key ->
          case value[key] do
            text when is_binary(text) ->
              if not String.starts_with?(text, "data:"), do: text

            _ ->
              nil
          end
        end)

      _ ->
        nil
    end)
  end

  defp unsupported(block, kind, label),
    do: %{type: "unsupported", kind: kind, label: label, value: media_metadata(block)}

  # The projection has already enforced the existing native payload budgets.
  # Inspect inline shape and base64 only; never decode, re-encode or fetch media.
  defp inline_image(%{"data" => %{"mime_type" => mime, "data" => data} = image})
       when not is_map_key(image, "source"),
       do: image_source(mime, data)

  defp inline_image(%{
         "data" => %{"source" => "base64", "media_type" => mime, "data" => data}
       }),
       do: image_source(mime, data)

  defp inline_image(%{"mimeType" => mime, "data" => data}),
    do: image_source(mime, data)

  defp inline_image(_), do: :error

  defp image_source(mime, data) when mime in @image_mimes and is_binary(data) do
    prefix = "data:" <> mime <> ";base64,"

    if String.starts_with?(data, prefix) do
      encoded = binary_part(data, byte_size(prefix), byte_size(data) - byte_size(prefix))
      if base64?(encoded), do: {:ok, mime, data}, else: :error
    else
      if base64?(data), do: {:ok, mime, prefix <> data}, else: :error
    end
  end

  defp image_source(_, _), do: :error

  defp base64?(data) do
    size = byte_size(data)

    size > 0 and rem(size, 4) == 0 and
      String.match?(data, ~r/\A[A-Za-z0-9+\/]+={0,2}\z/) and base64_tail?(data)
  end

  defp base64_tail?(data) do
    size = byte_size(data)

    cond do
      String.ends_with?(data, "==") ->
        binary_part(data, size - 3, 1) in ~w(A Q g w)

      String.ends_with?(data, "=") ->
        binary_part(data, size - 2, 1) in ~w(A E I M Q U Y c g k o s w 0 4 8)

      true ->
        true
    end
  end

  defp image_reference?(block) do
    Enum.any?([block, block["data"], block["source"]], fn
      value when is_map(value) ->
        Enum.any?(~w(uri url image_url), fn key ->
          is_binary(value[key]) and not String.starts_with?(value[key], "data:")
        end)

      _ ->
        false
    end)
  end

  defp image_metadata(block) do
    metadata = Map.drop(block, ~w(type data mimeType))

    data =
      case block["data"] do
        data when is_map(data) -> Map.drop(data, ~w(data source media_type mime_type))
        _ -> %{}
      end

    metadata = if data == %{}, do: metadata, else: Map.put(metadata, "data", data)
    media_metadata(metadata)
  end

  # References retain readable text, URIs and metadata without dumping media.
  defp media_metadata(value) when is_map(value) do
    Map.new(value, fn
      {key, data} when key in ~w(data blob) and is_binary(data) ->
        {key, omitted_media(data)}

      {key, data} ->
        {key, media_metadata(data)}
    end)
  end

  defp media_metadata(value) when is_list(value), do: Enum.map(value, &media_metadata/1)

  defp media_metadata("data:" <> _ = value), do: omitted_media(value)
  defp media_metadata(value), do: value

  defp omitted_media(value),
    do: %{omitted: "inline media", encodedCharacters: byte_size(value)}

  defp sidecars(result) do
    named =
      for key <- @sidecars, Map.has_key?(result, key) do
        %{key: key, label: String.capitalize(key), value: result[key]}
      end

    metadata = Map.drop(result, @sidecars ++ ~w(content error is_error))

    if metadata == %{},
      do: named,
      else: named ++ [%{key: "metadata", label: "Metadata", value: metadata}]
  end
end
