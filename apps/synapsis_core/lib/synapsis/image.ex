defmodule Synapsis.Image do
  @moduledoc "Image input support — encode images for LLM providers."

  @supported_types ~w(.png .jpg .jpeg .gif .webp)
  @max_size 20 * 1024 * 1024

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
            data = File.read!(path)
            base64 = Base.encode64(data)
            media_type = media_type(ext)
            {:ok, %{type: "image", media_type: media_type, data: base64}}

          {:error, reason} ->
            {:error, "cannot read file: #{reason}"}
        end
    end
  end

  def encode_url(url) do
    {:ok, %{type: "image_url", url: url}}
  end

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
end
