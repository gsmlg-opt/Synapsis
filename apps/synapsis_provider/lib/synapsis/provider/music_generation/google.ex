defmodule Synapsis.Provider.MusicGeneration.Google do
  @moduledoc """
  Explicit inactive Google music generation/edit callback (OpenClaw 488631c).

  Requests supply UTF-8 `:prompt` and a positive integer total `:timeout_ms`
  at most 2,147,483,647. Model defaults to lyria-3-clip-preview; model, prompt
  and lyrics use JavaScript trim. Optional instrumental and lyrics compose
  the source prompt together. Up to ten `:input_images` supply binary `:data`
  and optional MIME; trimmed MIME defaults to image/png. Prompt precedes the
  ordered references. Format is metadata only: MP3, or WAV for the exact Pro
  model. Duration, image URLs and filenames do not alter the wire request.

  Config supplies explicit `:api_key` and optional `:base_url`. The official
  Google root/version/openai normalization and SDK v1beta/model-resource
  routing are preserved; music does not apply image model aliases or strip
  google/. Explicit custom roots support local fixtures. URI normalization
  does not claim complete WHATWG/IDN or arbitrary URL encoding equivalence.
  No saved configuration, environment, credential or attribution discovery runs.

  All candidate/part tracks and trimmed text parts retain their source order;
  nonblank text wins over inline media in the same part. Camel/snake nullish
  precedence, URL-safe/canonical Base64, raw trimmed MIME and source filename
  extensions are retained. Unknown MIME defaults to WAV only for the exact
  Pro model, otherwise MP3. No maxTracks truncation, MIME sniffing or codec
  validation is performed. Results contain tracks, model, optional lyrics and
  source request metadata only.

  Call generate/2 from an already-supervised execution task. One linked HTTP
  owner and absolute deadline, starting before build, cover POST/read/decode
  and at most one source-defined unblocked no-audio retry. An audio result
  returns immediately. Transport/status errors and explicit terminal stops
  do not retry. Remaining time bounds pool/request/read waits and supplies the
  SDK X-Server-Timeout header, rounded up to seconds, on each POST. Positive
  `:max_audio_bytes` defaults to 16 MiB per track and `:max_response_bytes`
  to 64 MiB per JSON response; these are host additions to the SDK callback.

  The host uses Req rather than the Google SDK, omits SDK brand identity
  headers, and has no generic retries,
  redirects, downloads or polling. Failure, retry and abnormal-owner branches
  are source-reviewed, not execution-qualified. No public tool, native
  lifecycle, jobs, persistence or delivery is activated.
  """

  @base "https://generativelanguage.googleapis.com"
  @model "lyria-3-clip-preview"
  @pro "lyria-3-pro-preview"
  @default_cap 16 * 1024 * 1024
  @response_cap 64 * 1024 * 1024
  @max_timeout 2_147_483_647
  @js_space "[\\x{0009}-\\x{000D}\\x{0020}\\x{00A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}]"
  @js_trim Regex.compile!("\\A#{@js_space}+|#{@js_space}+\\z", "u")
  @extensions %{
    "image/avif" => "avif",
    "image/heic" => "heic",
    "image/heic-sequence" => "heic",
    "image/heif" => "heif",
    "image/heif-sequence" => "heif",
    "image/bmp" => "bmp",
    "image/jpg" => "jpg",
    "image/jpeg" => "jpg",
    "image/png" => "png",
    "image/svg+xml" => "svg",
    "image/webp" => "webp",
    "image/gif" => "gif",
    "audio/aiff" => "aiff",
    "audio/x-aiff" => "aiff",
    "audio/ogg" => "ogg",
    "audio/mpeg" => "mp3",
    "audio/mp3" => "mp3",
    "audio/wav" => "wav",
    "audio/wave" => "wav",
    "audio/x-wav" => "wav",
    "audio/flac" => "flac",
    "audio/aac" => "aac",
    "audio/amr" => "amr",
    "audio/opus" => "opus",
    "audio/webm" => "webm",
    "audio/x-m4a" => "m4a",
    "audio/m4a" => "m4a",
    "audio/mp4" => "m4a",
    "audio/x-caf" => "caf",
    "video/x-msvideo" => "avi",
    "video/x-m4v" => "m4v",
    "video/mp4" => "mp4",
    "video/x-matroska" => "mkv",
    "video/webm" => "webm",
    "video/x-flv" => "flv",
    "video/x-ms-wmv" => "wmv",
    "video/quicktime" => "mov",
    "application/pdf" => "pdf",
    "application/json" => "json",
    "application/yaml" => "yaml",
    "application/zip" => "zip",
    "application/gzip" => "gz",
    "application/x-tar" => "tar",
    "application/x-7z-compressed" => "7z",
    "application/vnd.rar" => "rar",
    "application/msword" => "doc",
    "application/vnd.ms-excel" => "xls",
    "application/vnd.ms-powerpoint" => "ppt",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document" => "docx",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" => "xlsx",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation" => "pptx",
    "text/csv" => "csv",
    "text/plain" => "txt",
    "text/markdown" => "md",
    "text/html" => "html",
    "text/xml" => "xml",
    "text/css" => "css",
    "application/xml" => "xml"
  }
  @mime_aliases %{
    "image/apng" => "image/png",
    "text/yaml" => "application/yaml",
    "application/x-yaml" => "application/yaml",
    "application/xml" => "text/xml",
    "video/vnd.avi" => "video/x-msvideo",
    "video/matroska" => "video/x-matroska"
  }

  @spec build_request(map(), map()) :: {:ok, map()} | {:error, term()}
  def build_request(request, config) when is_map(request) and is_map(config) do
    with :ok <- validate_request(request),
         :ok <- validate_config(config),
         {:ok, base} <- base_url(optional_string(config[:base_url]) || @base) do
      model = optional_string(request[:model]) || @model
      lyrics = optional_string(request[:lyrics])
      instrumental = request[:instrumental] == true
      images = request[:input_images] || []
      prompt = [trim(request.prompt)]

      prompt =
        if instrumental,
          do: prompt ++ ["Instrumental only. No vocals, no sung lyrics, no spoken word."],
          else: prompt

      prompt = if lyrics, do: prompt ++ ["Lyrics:\n" <> lyrics], else: prompt

      parts =
        [%{"text" => Enum.join(prompt, "\n\n")}] ++
          Enum.map(images, fn image ->
            %{
              "inlineData" => %{
                "mimeType" => optional_string(image[:mime_type]) || "image/png",
                "data" => Base.encode64(image.data)
              }
            }
          end)

      resource =
        if String.starts_with?(model, ["models/", "tunedModels/"]),
          do: model,
          else: "models/" <> model

      metadata = %{input_image_count: length(images), instrumental: instrumental}
      metadata = if lyrics, do: Map.put(metadata, :requested_lyrics, true), else: metadata
      metadata = optional(metadata, :requested_format, request[:format])

      {:ok,
       %{
         url: base <> "/" <> resource <> ":generateContent",
         body: %{
           "contents" => [%{"role" => "user", "parts" => parts}],
           "generationConfig" => %{"responseModalities" => ["AUDIO", "TEXT"]}
         },
         model: model,
         timeout_ms: request.timeout_ms,
         max_audio_bytes: Map.get(config, :max_audio_bytes, @default_cap),
         max_response_bytes: Map.get(config, :max_response_bytes, @response_cap),
         result_metadata: metadata
       }}
    end
  end

  def build_request(_, _), do: {:error, :invalid_request}

  @spec generate(map(), map()) :: {:ok, map()} | {:error, term()}
  def generate(request, config) do
    started = now_ms()

    with {:ok, built} <- build_request(request, config) do
      deadline = started + built.timeout_ms
      task = Task.async(fn -> perform(built, config.api_key, deadline, 2) end)

      case Task.yield(task, remaining(deadline)) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        nil -> {:error, :timeout}
        {:exit, _} -> {:error, :transport}
      end
    end
  end

  defp validate_request(request) do
    images = request[:input_images] || []
    model = optional_string(request[:model]) || @model

    cond do
      not text?(request[:prompt]) or
          not Enum.all?([:model, :lyrics], &optional_text?(request[&1])) ->
        {:error, :invalid_request}

      not (positive_integer?(request[:timeout_ms]) and request.timeout_ms <= @max_timeout) ->
        {:error, :invalid_timeout}

      request[:instrumental] not in [nil, true, false] ->
        {:error, :invalid_request}

      request[:format] not in [nil, "mp3", "wav"] or (request[:format] == "wav" and model != @pro) ->
        {:error, :invalid_format}

      String.contains?(model, ["..", "?", "&"]) ->
        {:error, :invalid_model}

      not is_list(images) or length(images) > 10 or not Enum.all?(images, &input_image?/1) ->
        {:error, :invalid_images}

      true ->
        :ok
    end
  end

  defp validate_config(config) do
    cond do
      not text?(config[:api_key]) or config.api_key == "" ->
        {:error, :missing_credentials}

      not optional_text?(config[:base_url]) ->
        {:error, :invalid_config}

      not positive_integer?(Map.get(config, :max_audio_bytes, @default_cap)) ->
        {:error, :invalid_max_audio_bytes}

      not positive_integer?(Map.get(config, :max_response_bytes, @response_cap)) ->
        {:error, :invalid_max_response_bytes}

      true ->
        :ok
    end
  end

  defp base_url(base) do
    with {:ok, uri} <- URI.new(trim(base)),
         scheme = String.downcase(uri.scheme || ""),
         port = uri.port || URI.default_port(scheme),
         true <- scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "",
         true <- is_integer(port) and port in 1..65_535 do
      host = String.downcase(uri.host)
      path = String.trim_trailing(uri.path || "", "/")

      path =
        if scheme == "https" and host == "generativelanguage.googleapis.com" do
          case Regex.replace(~r/\/openai\z/i, path, "") do
            "" -> "/v1beta"
            path -> path
          end
        else
          path
        end

      normalized =
        URI.to_string(%URI{scheme: scheme, host: host, port: port, path: path})
        |> String.trim_trailing("/")

      {:ok, Regex.replace(~r/\/v1beta\z/i, normalized, "") <> "/v1beta"}
    else
      _ -> {:error, :invalid_base_url}
    end
  end

  defp perform(built, api_key, deadline, attempts) do
    with {:ok, body} <- http(built, api_key, deadline),
         :ok <- check_deadline(deadline),
         {:ok, payload} when is_map(payload) <- Jason.decode(decoded_text(body)),
         {:ok, tracks, lyrics} <- read_output(payload, built, deadline),
         :ok <- check_deadline(deadline) do
      cond do
        tracks != [] ->
          result = %{tracks: tracks, model: built.model, metadata: built.result_metadata}
          {:ok, if(lyrics == [], do: result, else: Map.put(result, :lyrics, lyrics))}

        terminal_no_audio?(payload) ->
          {:error, :terminal_no_audio}

        attempts > 1 ->
          perform(built, api_key, deadline, attempts - 1)

        true ->
          {:error, :missing_audio}
      end
    else
      {:ok, _} -> {:error, :malformed_response}
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :transport}
  catch
    :exit, _ -> {:error, :transport}
  end

  defp read_output(payload, built, deadline) do
    with {:ok, candidates} <- optional_list(payload["candidates"]) do
      Enum.reduce_while(candidates, {:ok, {[], [], 0}}, fn candidate, {:ok, acc} ->
        case candidate_parts(candidate) do
          {:ok, parts} ->
            case read_parts(parts, acc, built, deadline) do
              {:ok, next} -> {:cont, {:ok, next}}
              error -> {:halt, error}
            end

          error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, {tracks, lyrics, _count}} -> {:ok, Enum.reverse(tracks), Enum.reverse(lyrics)}
        error -> error
      end
    end
  end

  defp read_parts(parts, acc, built, deadline) do
    Enum.reduce_while(parts, {:ok, acc}, fn part, {:ok, {tracks, lyrics, count}} ->
      with :ok <- check_deadline(deadline),
           true <- is_map(part) do
        text = optional_string(part["text"])

        inline =
          case part["inlineData"] do
            nil -> part["inline_data"]
            value -> value
          end

        data = if is_map(inline), do: optional_string(inline["data"]), else: nil

        cond do
          text ->
            {:cont, {:ok, {tracks, [text | lyrics], count}}}

          data ->
            case decode_audio(data, built.max_audio_bytes) do
              {:ok, bytes} ->
                mime =
                  optional_string(inline["mimeType"]) || optional_string(inline["mime_type"]) ||
                    "audio/mpeg"

                track = %{
                  data: bytes,
                  mime_type: mime,
                  filename: "track-#{count + 1}." <> extension(mime, built.model)
                }

                {:cont, {:ok, {[track | tracks], lyrics, count + 1}}}

              error ->
                {:halt, error}
            end

          true ->
            {:cont, {:ok, {tracks, lyrics, count}}}
        end
      else
        false -> {:halt, {:error, :malformed_response}}
        error -> {:halt, error}
      end
    end)
  end

  defp candidate_parts(candidate) when is_map(candidate) do
    case candidate["content"] do
      nil -> {:ok, []}
      content when is_map(content) -> optional_list(content["parts"])
      _ -> {:error, :malformed_response}
    end
  end

  defp candidate_parts(_), do: {:error, :malformed_response}
  defp optional_list(nil), do: {:ok, []}
  defp optional_list(value) when is_list(value), do: {:ok, value}
  defp optional_list(_), do: {:error, :malformed_response}

  defp terminal_no_audio?(payload) do
    feedback = if is_map(payload["promptFeedback"]), do: payload["promptFeedback"], else: %{}
    reason = optional_string(feedback["blockReason"])

    if reason && not String.ends_with?(reason, "_UNSPECIFIED") do
      true
    else
      Enum.any?(payload["candidates"] || [], fn candidate ->
        reason = optional_string(candidate["finishReason"])
        reason && reason not in ["STOP", "FINISH_REASON_UNSPECIFIED"]
      end)
    end
  end

  defp http(built, api_key, deadline) do
    timeout = remaining(deadline)

    if timeout == 0 do
      {:error, :timeout}
    else
      Req.Request.new()
      |> Req.Steps.attach()
      |> Req.merge(
        method: :post,
        url: built.url,
        body: Jason.encode!(built.body),
        headers: [
          {"x-goog-api-key", api_key},
          {"content-type", "application/json"},
          {"x-server-timeout", Integer.to_string(div(timeout + 999, 1000))}
        ],
        raw: true,
        compressed: false,
        retry: false,
        redirect: false,
        receive_timeout: timeout,
        request_timeout: timeout,
        finch: [pool_timeout: timeout],
        into: fn event, pair -> collect(event, pair, built.max_response_bytes) end
      )
      |> Req.request()
      |> response()
    end
  end

  defp collect({:data, data}, {request, response}, cap) do
    {size, chunks} = Req.Response.get_private(response, :google_music_body, {0, []})

    if size + byte_size(data) <= cap do
      {:cont,
       {request,
        Req.Response.put_private(
          response,
          :google_music_body,
          {size + byte_size(data), [data | chunks]}
        )}}
    else
      {:halt, {request, Req.Response.put_private(response, :google_music_limit, true)}}
    end
  end

  defp response({:ok, response}) do
    cond do
      Req.Response.get_private(response, :google_music_limit, false) ->
        {:error, :response_too_large}

      response.status not in 200..299 ->
        {:error, {:http_status, response.status}}

      true ->
        {_, chunks} = Req.Response.get_private(response, :google_music_body, {0, []})
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  defp response({:error, _}), do: {:error, :transport}

  defp decoded_text(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: String.replace_invalid(rest)
  defp decoded_text(bytes), do: String.replace_invalid(bytes)

  defp input_image?(image) when is_map(image),
    do: is_binary(image[:data]) and optional_text?(image[:mime_type])

  defp input_image?(_), do: false
  defp optional(map, _key, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)
  defp text?(value), do: is_binary(value) and String.valid?(value)
  defp optional_text?(nil), do: true
  defp optional_text?(value), do: text?(value)
  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp trim(text), do: Regex.replace(@js_trim, text, "")

  defp optional_string(value) when is_binary(value) do
    case trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp optional_string(_), do: nil
  defp now_ms, do: System.monotonic_time(:millisecond)
  defp remaining(deadline), do: max(0, deadline - now_ms())

  defp check_deadline(deadline),
    do: if(remaining(deadline) > 0, do: :ok, else: {:error, :timeout})

  defp extension(mime, model) do
    normalized = mime |> String.split(";", parts: 2) |> hd() |> trim() |> String.downcase()
    fallback = if model == @pro, do: "wav", else: "mp3"
    Map.get(@extensions, Map.get(@mime_aliases, normalized, normalized), fallback)
  end

  defp decode_audio(data, limit) do
    standard = String.contains?(data, ["+", "/"])
    url_safe = String.contains?(data, ["-", "_"])

    cleaned =
      data
      |> String.replace("-", "+")
      |> String.replace("_", "/")
      |> then(&Regex.replace(~r/[\x00-\x20]/, &1, ""))

    length = byte_size(cleaned)
    remainder = rem(length, 4)

    padding =
      cond do
        String.ends_with?(cleaned, "==") -> 2
        String.ends_with?(cleaned, "=") -> 1
        true -> 0
      end

    decoded_size = div(length * 3, 4) - padding
    canonical = cleaned <> String.duplicate("=", rem(4 - remainder, 4))

    cond do
      standard and url_safe ->
        {:error, :malformed_response}

      decoded_size > limit ->
        {:error, :audio_too_large}

      cleaned == "" or remainder == 1 or not Regex.match?(~r/\A[A-Za-z0-9+\/]*={0,2}\z/, cleaned) ->
        {:error, :malformed_response}

      remainder != 0 and padding != 0 ->
        {:error, :malformed_response}

      true ->
        with {:ok, bytes} <- Base.decode64(canonical),
             true <- byte_size(bytes) > 0 and Base.encode64(bytes) == canonical do
          {:ok, bytes}
        else
          _ -> {:error, :malformed_response}
        end
    end
  end
end
