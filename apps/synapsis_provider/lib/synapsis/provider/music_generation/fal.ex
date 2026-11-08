defmodule Synapsis.Provider.MusicGeneration.Fal do
  @moduledoc """
  Explicit, inactive FAL music-generation callback protocol.

  Requests retain exact UTF-8 prompt bytes and require a positive finite
  `:timeout_ms`. Optional model and lyrics use JavaScript whitespace trimming.
  MiniMax, ACE-Step and Stable Audio retain their distinct request bodies;
  an unknown nonblank model uses the source MiniMax-shaped callback branch.
  Input images are unsupported. Model capability normalization belongs to the
  caller, separately from this protocol's callback behavior.

  Config supplies an explicit `:api_key`, optional `:base_url` (fal.run by
  default), positive `:max_audio_bytes` and `:max_response_bytes` (16 MiB each),
  and optional `:request` containing only a string-map `:headers` override.
  This module does not resolve persisted providers, environment or credentials.

  Call `generate/2` from an already-supervised execution task. One linked HTTP
  owner and one absolute deadline cover POST, JSON parsing and the first
  candidate GET through shared Req.Finch. Source callbacks give POST and
  download separate budgets; the host requires one explicit whole-operation
  budget. Bodies are bounded; redirects, retries and polling are disabled.
  Only the first audio/audio_file candidate is downloaded. Specific response
  MIME wins candidate MIME, then audio/mpeg; candidate filenames are retained.
  Bytes are opaque and do not prove audio codec validity or music quality.

  Results retain the complete first track, optional trimmed lyrics, seed/tags,
  source URL and requested options. No jobs, storage, native tools, runtime
  discovery, completion turns or delivery are activated. Error and abnormal
  owner behavior is source-reviewed, not execution-qualified.
  """

  @base "https://fal.run"
  @model "fal-ai/minimax-music/v2.6"
  @ace "fal-ai/ace-step/prompt-to-audio"
  @stable "fal-ai/stable-audio-25/text-to-audio"
  @default_cap 16 * 1024 * 1024
  @max_timeout 2_147_483_647
  @js_space "[\\x{0009}-\\x{000D}\\x{0020}\\x{00A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}]"
  @js_trim Regex.compile!("\\A#{@js_space}+|#{@js_space}+\\z", "u")
  @transport_keys [
    :headers,
    :auth,
    :proxy,
    :tls,
    :allow_private_network,
    :allowPrivateNetwork,
    :dispatcher_policy,
    :request_options,
    :request_config
  ]

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
         {:ok, headers} <- configured_headers(config),
         model = optional_string(request[:model]) || @model,
         {:ok, body} <- request_body(request, model) do
      metadata =
        %{instrumental: request[:instrumental] == true}
        |> optional(:requested_format, request[:format])
        |> optional(:requested_duration_seconds, request[:duration_seconds])

      {:ok,
       %{
         url:
           String.trim_trailing(optional_string(config[:base_url]) || @base, "/") <> "/" <> model,
         model: model,
         body: body,
         headers: headers,
         timeout_ms: request.timeout_ms,
         max_audio_bytes: Map.get(config, :max_audio_bytes, @default_cap),
         max_response_bytes: Map.get(config, :max_response_bytes, @default_cap),
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
      task = Task.async(fn -> perform(built, deadline) end)

      case Task.yield(task, remaining(deadline)) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        nil -> {:error, :timeout}
        {:exit, _} -> {:error, :transport}
      end
    end
  end

  defp validate_request(request) do
    cond do
      not text?(request[:prompt]) or
          not Enum.all?([:model, :lyrics], &optional_text?(request[&1])) ->
        {:error, :invalid_request}

      not (positive_integer?(request[:timeout_ms]) and request.timeout_ms <= @max_timeout) ->
        {:error, :invalid_timeout}

      request[:format] not in [nil, "mp3", "wav"] ->
        {:error, :invalid_format}

      request[:instrumental] not in [nil, true, false] ->
        {:error, :invalid_request}

      not duration?(request[:duration_seconds]) ->
        {:error, :invalid_duration}

      request[:input_images] not in [nil, []] ->
        {:error, :unsupported_images}

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

      not positive_integer?(Map.get(config, :max_response_bytes, @default_cap)) ->
        {:error, :invalid_max_response_bytes}

      true ->
        :ok
    end
  end

  defp configured_headers(config) do
    request = config[:request] || %{}

    cond do
      Enum.any?(@transport_keys, &nonempty?(config[&1])) ->
        {:error, :unsupported_transport_config}

      not is_map(request) ->
        {:error, :unsupported_transport_config}

      Enum.any?(request, fn {key, value} -> key != :headers and nonempty?(value) end) ->
        {:error, :unsupported_transport_config}

      not header_map?(request[:headers] || %{}) ->
        {:error, :invalid_headers}

      true ->
        headers =
          Enum.reduce(
            request[:headers] || %{},
            %{"authorization" => "Key " <> config.api_key, "content-type" => "application/json"},
            fn {name, value}, acc ->
              case optional_string(value) do
                nil -> acc
                value -> Map.put(acc, name |> trim() |> String.downcase(:ascii), value)
              end
            end
          )

        {:ok, headers}
    end
  end

  defp header_map?(headers) when is_map(headers),
    do:
      Enum.all?(headers, fn {name, value} ->
        text?(name) and Regex.match?(~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/, trim(name)) and
          text?(value) and not String.contains?(value, ["\r", "\n", <<0>>])
      end)

  defp header_map?(_), do: false

  defp request_body(request, model) when model in [@ace, @stable] do
    cond do
      optional_string(request[:lyrics]) != nil ->
        {:error, :unsupported_lyrics}

      model == @stable and request[:instrumental] == true ->
        {:error, :unsupported_instrumental}

      true ->
        body = %{"prompt" => request.prompt}

        body =
          if request[:instrumental] == true, do: Map.put(body, "instrumental", true), else: body

        key = if model == @stable, do: "seconds_total", else: "duration"
        {:ok, optional(body, key, request[:duration_seconds])}
    end
  end

  defp request_body(request, _model) do
    lyrics = optional_string(request[:lyrics])
    instrumental = request[:instrumental] == true

    if lyrics && instrumental do
      {:error, :conflicting_lyrics}
    else
      body =
        %{
          "prompt" => request.prompt,
          "audio_setting" => %{
            "sample_rate" => 44_100,
            "bitrate" => 256_000,
            "format" => request[:format] || "mp3"
          }
        }
        |> optional("lyrics", lyrics)
        |> optional("duration", request[:duration_seconds])

      body = if instrumental, do: Map.put(body, "is_instrumental", true), else: body

      body =
        if is_nil(lyrics) and not instrumental,
          do: Map.put(body, "lyrics_optimizer", true),
          else: body

      {:ok, body}
    end
  end

  defp perform(built, deadline) do
    with {:ok, response} <-
           http(
             :post,
             built.url,
             [body: Jason.encode!(built.body), headers: built.headers],
             built.max_response_bytes,
             deadline
           ),
         :ok <- check_deadline(deadline),
         {:ok, payload} <- decode_payload(response.body),
         {:ok, candidate} <- candidate(payload),
         {:ok, audio} <- http(:get, candidate.url, [], built.max_audio_bytes, deadline),
         :ok <- check_deadline(deadline) do
      mime =
        specific_mime(audio.headers |> Map.get("content-type", []) |> List.first()) ||
          specific_mime(candidate.mime_type) || "audio/mpeg"

      track = %{
        data: audio.body,
        mime_type: mime,
        filename: candidate.filename || "track-1." <> extension(mime),
        metadata: %{url: candidate.url}
      }

      metadata =
        built.result_metadata
        |> Map.put(:audio_url, candidate.url)
        |> optional(:seed, payload["seed"])
        |> optional(:tags, payload["tags"])

      result = %{tracks: [track], model: built.model, metadata: metadata}

      case optional_string(payload["lyrics"]) do
        nil -> {:ok, result}
        lyrics -> {:ok, Map.put(result, :lyrics, [lyrics])}
      end
    end
  rescue
    _ -> {:error, :transport}
  catch
    :exit, _ -> {:error, :transport}
  end

  defp decode_payload(body) do
    body =
      case body do
        <<0xEF, 0xBB, 0xBF, rest::binary>> -> rest
        body -> body
      end

    with true <- String.valid?(body),
         {:ok, value} when is_map(value) <- Jason.decode(body),
         do: {:ok, value},
         else: (_ -> {:error, :malformed_response})
  end

  defp candidate(payload) do
    case Enum.find_value(["audio", "audio_file"], &file_candidate(payload[&1])) do
      nil -> {:error, :missing_audio}
      candidate -> {:ok, candidate}
    end
  end

  defp file_candidate(value) when is_binary(value) do
    case optional_string(value) do
      nil -> nil
      url -> %{url: url, mime_type: nil, filename: nil}
    end
  end

  defp file_candidate(value) when is_map(value) do
    case optional_string(value["url"]) do
      nil ->
        nil

      url ->
        %{
          url: url,
          mime_type: optional_string(value["content_type"]),
          filename: optional_string(value["file_name"])
        }
    end
  end

  defp file_candidate(_), do: nil

  defp specific_mime(value) do
    case optional_string(value) do
      nil ->
        nil

      text ->
        mime = text |> String.split(";", parts: 2) |> hd() |> trim() |> String.downcase()
        if mime in ["", "application/octet-stream", "binary/octet-stream"], do: nil, else: mime
    end
  end

  defp http(method, url, options, limit, deadline) do
    timeout = remaining(deadline)

    if timeout == 0 do
      {:error, :timeout}
    else
      Req.Request.new()
      |> Req.Steps.attach()
      |> Req.merge(
        options ++
          [
            method: method,
            url: url,
            raw: true,
            compressed: false,
            into: fn event, pair -> collect(event, pair, limit) end,
            retry: false,
            redirect: false,
            receive_timeout: timeout,
            request_timeout: timeout,
            finch: [pool_timeout: timeout]
          ]
      )
      |> Req.request()
      |> response()
    end
  end

  defp collect({:data, data}, {request, response}, limit) do
    {size, chunks} = Req.Response.get_private(response, :fal_music_body, {0, []})

    if size + byte_size(data) <= limit,
      do:
        {:cont,
         {request,
          Req.Response.put_private(
            response,
            :fal_music_body,
            {size + byte_size(data), [data | chunks]}
          )}},
      else: {:halt, {request, Req.Response.put_private(response, :fal_music_limit, true)}}
  end

  defp response({:ok, response}) do
    cond do
      Req.Response.get_private(response, :fal_music_limit, false) ->
        {:error, :response_too_large}

      response.status not in 200..299 ->
        {:error, {:http_status, response.status}}

      true ->
        {_, chunks} = Req.Response.get_private(response, :fal_music_body, {0, []})

        {:ok,
         %{body: chunks |> Enum.reverse() |> IO.iodata_to_binary(), headers: response.headers}}
    end
  end

  defp response({:error, _}), do: {:error, :transport}
  defp optional(map, _key, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)
  defp nonempty?(value), do: value not in [nil, %{}, []]
  defp text?(value), do: is_binary(value) and String.valid?(value)
  defp optional_text?(nil), do: true
  defp optional_text?(value), do: text?(value)
  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp duration?(nil), do: true
  defp duration?(value), do: is_number(value) and value > 0
  defp trim(text), do: Regex.replace(@js_trim, text, "")

  defp optional_string(value) when is_binary(value) do
    case trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp optional_string(_), do: nil
  defp now_ms, do: System.monotonic_time(:millisecond)
  defp remaining(deadline), do: max(0, deadline - now_ms())

  defp check_deadline(deadline),
    do: if(remaining(deadline) > 0, do: :ok, else: {:error, :timeout})

  defp extension(mime), do: Map.get(@extensions, Map.get(@mime_aliases, mime, mime), "mp3")
end
