defmodule Synapsis.Workspace.Media do
  @moduledoc """
  Host-owned, content-addressed storage for opaque audio, image and video bytes.

  Formats label audio as MP3, Opus, WAV or opaque PCM and images as PNG, JPEG or
  WebP. This module does not decode media. Video storage preserves the exact supplied MIME
  type and derives only a format label from its normalized base. Portable
  descriptors contain no host paths or bytes.
  The default root is `Synapsis.Config.Store.config_dir()/media`, separate from
  the Workspace blob store and its garbage collection. Callers can bind another
  host-owned root with `:root`.

  Writes sync and close a same-directory temporary file before publishing with a
  no-replace hard link. Existing content is checked without overwriting it. This
  provides atomic file visibility, not a transaction with Concord or directory
  durability across power loss. There is no automatic deletion or garbage
  collection. Crash recovery and caller cancellation are outside this API.

  Storage functions accept `:max_bytes` (default 16 MiB for audio/video, 64 MiB for images)
  and an absolute monotonic
  millisecond `:deadline` (default 30 seconds from entry). Deadlines are checked
  between filesystem phases; they do not interrupt a blocked filesystem call.
  No persistent process or effect-cleanup owner is created for stored media.
  """

  @default_max_bytes 16 * 1024 * 1024
  @default_image_max_bytes 64 * 1024 * 1024
  @default_timeout 30_000
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
  @uri_pattern ~r/\Asynapsis-media:\/\/audio\/([a-f0-9]{64})\.(mp3|opus|aac|flac|wav|pcm|ogg|webm|amr|audio)\z/
  @image_uri_pattern ~r/\Asynapsis-media:\/\/image\/([a-f0-9]{64})\.(png|jpeg|webp)\z/
  @video_uri_pattern ~r/\Asynapsis-media:\/\/video\/([a-f0-9]{64})\.(avi|m4v|mp4|mkv|webm|flv|wmv|mov)\z/
  @video_formats %{
    "video/x-msvideo" => "avi",
    "video/vnd.avi" => "avi",
    "video/x-m4v" => "m4v",
    "video/mp4" => "mp4",
    "video/x-matroska" => "mkv",
    "video/matroska" => "mkv",
    "video/webm" => "webm",
    "video/x-flv" => "flv",
    "video/x-ms-wmv" => "wmv",
    "video/quicktime" => "mov"
  }
  @js_space "[\\x{0009}-\\x{000D}\\x{0020}\\x{00A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}]"
  @js_trim Regex.compile!("\\A#{@js_space}+|#{@js_space}+\\z", "u")

  @type descriptor :: %{String.t() => String.t() | non_neg_integer()}
  @type error :: {:error, atom() | {:media_io, atom()}}

  @doc "Stores bytes and returns their stable JSON-safe audio descriptor."
  @spec put_audio(binary(), String.t(), keyword()) :: {:ok, descriptor()} | error()
  def put_audio(audio, format, opts \\ [])

  def put_audio(audio, format, opts) when is_binary(audio) and is_map_key(@formats, format) do
    with {:ok, settings} <- settings(opts),
         :ok <- check_deadline(settings.deadline),
         :ok <- check_size(audio, settings.max_bytes) do
      sha256 = hash(audio)
      descriptor = descriptor(sha256, format, byte_size(audio))
      path = stored_path(settings.root, sha256, format)

      with :ok <- check_deadline(settings.deadline),
           :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- check_deadline(settings.deadline),
           :ok <- publish(audio, path, sha256, settings) do
        {:ok, descriptor}
      else
        {:error, reason} -> tagged_error(reason)
      end
    end
  end

  def put_audio(audio, _format, _opts) when not is_binary(audio), do: {:error, :invalid_audio}
  def put_audio(_audio, _format, _opts), do: {:error, :invalid_format}

  @doc "Reads a stable audio URI, bounded by byte count and verified by SHA-256."
  @spec read_audio(String.t(), keyword()) ::
          {:ok, %{audio: binary(), descriptor: descriptor()}} | error()
  def read_audio(uri, opts \\ []) do
    with {:ok, settings} <- settings(opts),
         {:ok, sha256, format} <- parse_uri(uri),
         :ok <- check_deadline(settings.deadline),
         {:ok, audio} <-
           read_verified(stored_path(settings.root, sha256, format), sha256, settings) do
      {:ok, %{audio: audio, descriptor: descriptor(sha256, format, byte_size(audio))}}
    end
  end

  @doc "Stores bytes and returns their stable JSON-safe image descriptor."
  @spec put_image(binary(), String.t(), keyword()) :: {:ok, descriptor()} | error()
  def put_image(image, format, opts \\ [])

  def put_image(image, format, opts)
      when is_binary(image) and is_map_key(@image_formats, format) do
    with {:ok, settings} <- settings(opts, @default_image_max_bytes),
         :ok <- check_deadline(settings.deadline),
         :ok <- check_size(image, settings.max_bytes) do
      sha256 = hash(image)
      descriptor = image_descriptor(sha256, format, byte_size(image))
      path = stored_path(settings.root, sha256, format)

      with :ok <- check_deadline(settings.deadline),
           :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- check_deadline(settings.deadline),
           :ok <- publish(image, path, sha256, settings) do
        {:ok, descriptor}
      else
        {:error, reason} -> tagged_error(reason)
      end
    end
  end

  def put_image(image, _format, _opts) when not is_binary(image), do: {:error, :invalid_image}
  def put_image(_image, _format, _opts), do: {:error, :invalid_format}

  @doc "Reads a stable image URI, bounded by byte count and verified by SHA-256."
  @spec read_image(String.t(), keyword()) ::
          {:ok, %{image: binary(), descriptor: descriptor()}} | error()
  def read_image(uri, opts \\ []) do
    with {:ok, settings} <- settings(opts, @default_image_max_bytes),
         {:ok, sha256, format} <- parse_image_uri(uri),
         :ok <- check_deadline(settings.deadline),
         {:ok, image} <-
           read_verified(stored_path(settings.root, sha256, format), sha256, settings) do
      {:ok, %{image: image, descriptor: image_descriptor(sha256, format, byte_size(image))}}
    end
  end

  @doc "Stores opaque video bytes while preserving the exact supplied MIME type."
  @spec put_video(binary(), String.t(), keyword()) :: {:ok, descriptor()} | error()
  def put_video(video, mime_type, opts \\ [])

  def put_video(video, mime_type, opts) when is_binary(video) do
    with {:ok, format} <- video_format(mime_type),
         {:ok, settings} <- settings(opts),
         :ok <- check_deadline(settings.deadline),
         :ok <- check_size(video, settings.max_bytes) do
      sha256 = hash(video)
      descriptor = video_descriptor(sha256, format, byte_size(video), mime_type)
      path = stored_path(settings.root, sha256, format)

      with :ok <- validate_video_descriptor(descriptor),
           :ok <- check_deadline(settings.deadline),
           :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- check_deadline(settings.deadline),
           :ok <- publish(video, path, sha256, settings) do
        {:ok, descriptor}
      else
        {:error, reason} -> tagged_error(reason)
      end
    end
  end

  def put_video(_video, _mime_type, _opts), do: {:error, :invalid_video}

  @doc "Reads verified video bytes using their complete, original MIME-bearing descriptor."
  @spec read_video(descriptor(), keyword()) ::
          {:ok, %{video: binary(), descriptor: descriptor()}} | error()
  def read_video(descriptor, opts \\ []) do
    with :ok <- validate_video_descriptor(descriptor),
         {:ok, settings} <- settings(opts),
         :ok <- check_deadline(settings.deadline),
         {:ok, video} <-
           read_verified(
             stored_path(settings.root, descriptor["sha256"], descriptor["format"]),
             descriptor["sha256"],
             settings
           ),
         true <- byte_size(video) == descriptor["byte_size"] do
      {:ok, %{video: video, descriptor: descriptor}}
    else
      false -> {:error, :invalid_descriptor}
      error -> error
    end
  end

  @doc "Validates a complete video descriptor without reading its stored bytes."
  @spec validate_video_descriptor(term()) :: :ok | {:error, :invalid_descriptor}
  def validate_video_descriptor(
        %{
          "uri" => uri,
          "sha256" => sha256,
          "byte_size" => size,
          "format" => format,
          "mime_type" => mime_type
        } = descriptor
      )
      when map_size(descriptor) == 5 and is_binary(uri) and is_binary(sha256) and
             is_integer(size) and size >= 0 and is_binary(format) do
    with [^sha256, ^format] <- Regex.run(@video_uri_pattern, uri, capture: :all_but_first),
         {:ok, ^format} <- video_format(mime_type) do
      :ok
    else
      _ -> {:error, :invalid_descriptor}
    end
  end

  def validate_video_descriptor(_descriptor), do: {:error, :invalid_descriptor}

  defp settings(opts, default_max_bytes \\ @default_max_bytes)

  defp settings(opts, default_max_bytes) when is_list(opts) do
    if Keyword.keyword?(opts) do
      root =
        Keyword.get_lazy(opts, :root, fn ->
          Path.join(Synapsis.Config.Store.config_dir(), "media")
        end)

      max_bytes = Keyword.get(opts, :max_bytes, default_max_bytes)
      deadline = Keyword.get(opts, :deadline, now() + @default_timeout)

      if is_binary(root) and root != "" and is_integer(max_bytes) and max_bytes > 0 and
           is_integer(deadline) do
        {:ok, %{root: Path.expand(root), max_bytes: max_bytes, deadline: deadline}}
      else
        {:error, :invalid_options}
      end
    else
      {:error, :invalid_options}
    end
  end

  defp settings(_opts, _default_max_bytes), do: {:error, :invalid_options}

  defp publish(audio, path, sha256, settings) do
    temporary =
      path <> ".tmp-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    with :ok <- check_deadline(settings.deadline),
         {:ok, file} <- File.open(temporary, [:write, :binary, :raw, :exclusive]) do
      result =
        with :ok <- write_temporary(file, audio, settings.deadline),
             :ok <- check_deadline(settings.deadline) do
          case File.ln(temporary, path) do
            :ok -> check_deadline(settings.deadline)
            {:error, :eexist} -> match_existing(path, sha256, audio, settings)
            {:error, reason} -> tagged_error(reason)
          end
        end

      case File.rm(temporary) do
        :ok ->
          with :ok <- result, do: check_deadline(settings.deadline)

        {:error, reason} ->
          tagged_error(reason)
      end
    end
  end

  defp write_temporary(file, audio, deadline) do
    result =
      with :ok <- check_deadline(deadline),
           :ok <- :file.write(file, audio),
           :ok <- check_deadline(deadline),
           :ok <- :file.sync(file),
           :ok <- check_deadline(deadline) do
        :ok
      end

    closed = File.close(file)

    with :ok <- result,
         :ok <- closed,
         :ok <- check_deadline(deadline) do
      :ok
    end
  end

  defp match_existing(path, sha256, audio, settings) do
    with {:ok, stored} <- read_verified(path, sha256, settings) do
      matches = stored == audio

      with :ok <- check_deadline(settings.deadline) do
        if matches, do: :ok, else: {:error, :content_mismatch}
      end
    end
  end

  defp read_verified(path, sha256, settings) do
    with :ok <- check_deadline(settings.deadline),
         {:ok, audio} <- read_bounded(path, settings),
         :ok <- check_deadline(settings.deadline),
         :ok <- check_size(audio, settings.max_bytes) do
      verified = hash(audio) == sha256

      with :ok <- check_deadline(settings.deadline) do
        if verified, do: {:ok, audio}, else: {:error, :hash_mismatch}
      end
    else
      {:error, reason} -> tagged_error(reason)
    end
  end

  defp read_bounded(path, settings) do
    with {:ok, file} <- File.open(path, [:read, :binary, :raw]) do
      result =
        with :ok <- check_deadline(settings.deadline) do
          :file.read(file, settings.max_bytes + 1)
        end

      closed = File.close(file)

      with :ok <- closed do
        case result do
          {:ok, audio} -> {:ok, audio}
          :eof -> {:ok, <<>>}
          {:error, reason} -> tagged_error(reason)
        end
      end
    end
  end

  defp parse_uri(uri) when is_binary(uri) do
    case Regex.run(@uri_pattern, uri, capture: :all_but_first) do
      [sha256, format] -> {:ok, sha256, format}
      nil -> {:error, :invalid_uri}
    end
  end

  defp parse_uri(_uri), do: {:error, :invalid_uri}

  defp parse_image_uri(uri) when is_binary(uri) do
    case Regex.run(@image_uri_pattern, uri, capture: :all_but_first) do
      [sha256, format] -> {:ok, sha256, format}
      nil -> {:error, :invalid_uri}
    end
  end

  defp parse_image_uri(_uri), do: {:error, :invalid_uri}

  defp descriptor(sha256, format, byte_size) do
    %{
      "uri" => "synapsis-media://audio/#{sha256}.#{format}",
      "sha256" => sha256,
      "byte_size" => byte_size,
      "mime_type" => Map.fetch!(@formats, format),
      "format" => format
    }
  end

  defp image_descriptor(sha256, format, byte_size) do
    %{
      "uri" => "synapsis-media://image/#{sha256}.#{format}",
      "sha256" => sha256,
      "byte_size" => byte_size,
      "mime_type" => Map.fetch!(@image_formats, format),
      "format" => format
    }
  end

  defp video_descriptor(sha256, format, byte_size, mime_type) do
    %{
      "uri" => "synapsis-media://video/#{sha256}.#{format}",
      "sha256" => sha256,
      "byte_size" => byte_size,
      "mime_type" => mime_type,
      "format" => format
    }
  end

  defp video_format(mime_type) when is_binary(mime_type) do
    if String.valid?(mime_type) do
      base = mime_type |> String.split(";", parts: 2) |> hd()
      base = @js_trim |> Regex.replace(base, "") |> String.downcase()

      if base == "",
        do: {:error, :invalid_mime_type},
        else: {:ok, Map.get(@video_formats, base, "mp4")}
    else
      {:error, :invalid_mime_type}
    end
  end

  defp video_format(_mime_type), do: {:error, :invalid_mime_type}

  defp stored_path(root, sha256, format) do
    <<a::binary-size(2), b::binary-size(2), rest::binary>> = sha256
    Path.join([root, a, b, rest <> "." <> format])
  end

  defp hash(audio), do: :crypto.hash(:sha256, audio) |> Base.encode16(case: :lower)

  defp check_size(audio, max_bytes) do
    if byte_size(audio) <= max_bytes, do: :ok, else: {:error, :too_large}
  end

  defp check_deadline(deadline) do
    if now() < deadline, do: :ok, else: {:error, :timeout}
  end

  defp tagged_error(reason)
       when reason in [:timeout, :too_large, :hash_mismatch, :content_mismatch],
       do: {:error, reason}

  defp tagged_error({:media_io, reason}), do: {:error, {:media_io, reason}}
  defp tagged_error(reason) when is_atom(reason), do: {:error, {:media_io, reason}}

  defp now, do: System.monotonic_time(:millisecond)
end
