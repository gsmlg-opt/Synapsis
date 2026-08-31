defmodule Synapsis.Image do
  @moduledoc "Image input support — encode images for LLM providers."

  @supported_types ~w(.png .jpg .jpeg .gif .webp)
  @max_size 20 * 1024 * 1024
  @json_media_types ~w(image/png image/jpeg image/gif image/webp)
  @max_json_images 4
  @max_json_image_bytes 5 * 1024 * 1024
  @max_json_total_bytes 10 * 1024 * 1024
  @max_json_base64_bytes 4 * div(@max_json_image_bytes + 2, 3)

  @doc "Returns true if the given file path has a supported image extension."
  def supported?(path) do
    ext = Path.extname(path) |> String.downcase()
    ext in @supported_types
  end

  def encode_file(path) do
    ext = Path.extname(path) |> String.downcase()

    cond do
      ext not in @supported_types ->
        {:error, "unsupported image type: #{ext}"}

      not File.exists?(path) ->
        {:error, "file not found: #{path}"}

      true ->
        case File.stat(path) do
          {:ok, %{size: size}} when size > @max_size ->
            {:error,
             "image too large (#{div(size, 1024 * 1024)}MB, max #{div(@max_size, 1024 * 1024)}MB)"}

          {:ok, _} ->
            case File.read(path) do
              {:ok, data} ->
                base64 = Base.encode64(data)
                media_type = media_type(ext)
                {:ok, %{type: "image", media_type: media_type, data: base64}}

              {:error, reason} ->
                {:error, "cannot read file: #{reason}"}
            end

          {:error, reason} ->
            {:error, "cannot read file: #{reason}"}
        end
    end
  end

  def encode_url(url) do
    {:ok, %{type: "image_url", url: url}}
  end

  @doc "Decodes and validates Base64 image maps received through a JSON client payload."
  def decode_payloads(images) when is_list(images) do
    if length(images) > @max_json_images do
      {:error, {:too_many_images, "Attach at most 4 images"}}
    else
      decode_json_images(images)
    end
  end

  def decode_payloads(_images), do: {:error, {:invalid_payload, "Invalid image attachment"}}

  def to_anthropic_content(%{type: "image", media_type: mt, data: data}) do
    %{
      "type" => "image",
      "source" => %{
        "type" => "base64",
        "media_type" => mt,
        "data" => data
      }
    }
  end

  def to_openai_content(%{type: "image", media_type: mt, data: data}) do
    %{
      "type" => "image_url",
      "image_url" => %{
        "url" => "data:#{mt};base64,#{data}"
      }
    }
  end

  def to_openai_content(%{type: "image_url", url: url}) do
    %{
      "type" => "image_url",
      "image_url" => %{"url" => url}
    }
  end

  def to_google_content(%{type: "image", media_type: mt, data: data}) do
    %{
      "inlineData" => %{
        "mimeType" => mt,
        "data" => data
      }
    }
  end

  @doc "Returns the MIME media type for the given extension."
  def media_type(".png"), do: "image/png"
  def media_type(".jpg"), do: "image/jpeg"
  def media_type(".jpeg"), do: "image/jpeg"
  def media_type(".gif"), do: "image/gif"
  def media_type(".webp"), do: "image/webp"
  def media_type(ext), do: {:error, "unsupported extension: #{ext}"}

  defp decode_json_images(images) do
    images
    |> Enum.reduce_while({[], 0}, fn payload, {parts, total_bytes} ->
      with {:ok, part, size} <- decode_json_image(payload),
           new_total = total_bytes + size,
           :ok <- validate_total_size(new_total) do
        {:cont, {[part | parts], new_total}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      {parts, _total_bytes} -> {:ok, Enum.reverse(parts)}
    end
  end

  defp decode_json_image(%{"media_type" => media_type, "data" => data})
       when is_binary(media_type) and is_binary(data) do
    with :ok <- validate_media_type(media_type),
         :ok <- validate_encoded_size(data),
         {:ok, bytes} <- decode_base64(data),
         :ok <- validate_decoded_size(bytes),
         :ok <- validate_signature(media_type, bytes) do
      {:ok, %Synapsis.Part.Image{media_type: media_type, data: data, path: nil}, byte_size(bytes)}
    end
  end

  defp decode_json_image(_payload),
    do: {:error, {:invalid_payload, "Invalid image attachment"}}

  defp validate_media_type(media_type) when media_type in @json_media_types, do: :ok

  defp validate_media_type(_media_type),
    do: {:error, {:unsupported_media_type, "Unsupported image type"}}

  defp validate_encoded_size(data) when byte_size(data) <= @max_json_base64_bytes, do: :ok

  defp validate_encoded_size(_data),
    do: {:error, {:image_too_large, "Each image must be 5 MiB or smaller"}}

  defp decode_base64(""), do: {:error, {:invalid_image, "Invalid image attachment"}}

  defp decode_base64(data) do
    case Base.decode64(data) do
      {:ok, <<>>} -> {:error, {:invalid_image, "Invalid image attachment"}}
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, {:invalid_base64, "Invalid image attachment"}}
    end
  end

  defp validate_decoded_size(bytes) when byte_size(bytes) <= @max_json_image_bytes, do: :ok

  defp validate_decoded_size(_bytes),
    do: {:error, {:image_too_large, "Each image must be 5 MiB or smaller"}}

  defp validate_total_size(size) when size <= @max_json_total_bytes, do: :ok

  defp validate_total_size(_size),
    do: {:error, {:images_too_large, "Images must total 10 MiB or less"}}

  defp validate_signature(media_type, bytes) do
    if detected_media_type(bytes) == media_type do
      :ok
    else
      {:error, {:media_type_mismatch, "Image content does not match its type"}}
    end
  end

  defp detected_media_type(<<0x89, "PNG\r\n", 0x1A, "\n", _rest::binary>>), do: "image/png"
  defp detected_media_type(<<0xFF, 0xD8, 0xFF, _rest::binary>>), do: "image/jpeg"
  defp detected_media_type(<<"GIF87a", _rest::binary>>), do: "image/gif"
  defp detected_media_type(<<"GIF89a", _rest::binary>>), do: "image/gif"

  defp detected_media_type(<<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>>),
    do: "image/webp"

  defp detected_media_type(_bytes), do: nil
end
