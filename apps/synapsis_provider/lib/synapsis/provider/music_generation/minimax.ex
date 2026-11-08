defmodule Synapsis.Provider.MusicGeneration.MiniMax do
  @moduledoc """
  Explicit inactive MiniMax music callback protocol (OpenClaw 488631c).

  Atom-keyed requests require UTF-8 `:prompt` and a positive integer total
  `:timeout_ms` at most 2,147,483,647. Model defaults to music-2.6; model,
  prompt and lyrics use JavaScript whitespace trimming. Instrumental, lyrics
  optimizer, MP3 audio settings and stream/hex fields follow the source.
  Duration is source-unused. Input images and non-MP3 formats are unsupported.

  Config supplies explicit `:api_key`, optional `:base_url` (api.minimax.io),
  and optional `:provider_id` (minimax or minimax-portal). Only the URL origin
  is used, discarding path/query/fragment. This host uses URI normalization
  for explicit HTTP(S) hosts, not the full WHATWG URL/IDN parser. Optional
  `:request` supports only string-map `:headers`; JSON content type is forced
  after overrides. There is no environment, saved credential or region lookup.

  The callback consumes direct audio, JSON inline hex/URL, or complete SSE
  envelopes. Direct/downloaded audio retains trimmed raw MIME, including case
  and parameters; inline/SSE output uses audio/mpeg. The first completed SSE
  frame contributes its audio only when no earlier audio chunks exist. Lyrics
  may be literal text or UTF-8 hex. One track, model and source task/URL/request
  metadata are retained. Opaque bytes do not prove codec or music quality.

  Call generate/2 from an already-supervised execution task. A linked HTTP
  owner and one absolute total deadline cover POST/read/optional GET/decode.
  Audio defaults to 16 MiB; the JSON/SSE envelope defaults to five times the
  audio cap plus 64 KiB. Positive `:max_audio_bytes` and `:max_response_bytes`
  can override these bounds. Read/pool waits use the remaining total budget.
  The source defaults to 300 seconds and wraps downloads in a retry helper;
  this host requires explicit total time and does not retry or redirect.

  No polling, persisted provider discovery, job/tool registration, native
  lifecycle, storage or delivery is activated. Failure and abnormal-owner
  behavior are source-reviewed, not execution-qualified.
  """

  @base "https://api.minimax.io"
  @model "music-2.6"
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
         {:ok, origin} <- origin(optional_string(config[:base_url]) || @base),
         {:ok, headers} <- configured_headers(config) do
      model = optional_string(request[:model]) || @model
      lyrics = optional_string(request[:lyrics])
      instrumental = request[:instrumental] == true
      cap = Map.get(config, :max_audio_bytes, @default_cap)

      body = %{
        "model" => model,
        "prompt" => trim(request.prompt),
        "stream" => true,
        "output_format" => "hex",
        "audio_setting" => %{"sample_rate" => 44_100, "bitrate" => 256_000, "format" => "mp3"}
      }

      body = if instrumental, do: Map.put(body, "is_instrumental", true), else: body

      body =
        cond do
          lyrics -> Map.put(body, "lyrics", lyrics)
          instrumental -> body
          true -> Map.put(body, "lyrics_optimizer", true)
        end

      metadata = %{instrumental: instrumental}
      metadata = if lyrics, do: Map.put(metadata, :requested_lyrics, true), else: metadata

      {:ok,
       %{
         url: origin <> "/v1/music_generation",
         model: model,
         body: body,
         headers: Map.put(headers, "content-type", "application/json"),
         timeout_ms: request.timeout_ms,
         max_audio_bytes: cap,
         max_response_bytes: Map.get(config, :max_response_bytes, cap * 5 + 65_536),
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

      request[:format] not in [nil, "mp3"] ->
        {:error, :invalid_format}

      request[:instrumental] not in [nil, true, false] ->
        {:error, :invalid_request}

      request[:instrumental] == true and not is_nil(optional_string(request[:lyrics])) ->
        {:error, :conflicting_lyrics}

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

      config[:provider_id] not in [nil, "minimax", "minimax-portal"] ->
        {:error, :invalid_config}

      not positive_integer?(Map.get(config, :max_audio_bytes, @default_cap)) ->
        {:error, :invalid_max_audio_bytes}

      not positive_integer?(
        Map.get(
          config,
          :max_response_bytes,
          Map.get(config, :max_audio_bytes, @default_cap) * 5 + 65_536
        )
      ) ->
        {:error, :invalid_max_response_bytes}

      true ->
        :ok
    end
  end

  defp origin(base) do
    with {:ok, uri} <- URI.new(trim(base)),
         scheme = String.downcase(uri.scheme || ""),
         port = uri.port || URI.default_port(scheme),
         true <- scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "",
         true <- is_integer(port) and port in 1..65_535 do
      {:ok, URI.to_string(%URI{scheme: scheme, host: String.downcase(uri.host), port: port})}
    else
      _ -> {:error, :invalid_base_url}
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
            %{"authorization" => "Bearer " <> config.api_key},
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

  defp perform(built, deadline) do
    with {:ok, response} <-
           http(
             :post,
             built.url,
             [body: Jason.encode!(built.body), headers: built.headers],
             built,
             deadline,
             :submission
           ),
         :ok <- check_deadline(deadline),
         {:ok, track, lyrics, metadata} <- output(response, built, deadline),
         :ok <- check_deadline(deadline) do
      result = %{tracks: [track], model: built.model, metadata: metadata}
      {:ok, if(lyrics in [nil, ""], do: result, else: Map.put(result, :lyrics, [lyrics]))}
    end
  rescue
    _ -> {:error, :transport}
  catch
    :exit, _ -> {:error, :transport}
  end

  defp output(response, built, deadline) do
    mime = optional_string(response.mime_type) || ""
    lower = String.downcase(mime)

    cond do
      String.starts_with?(lower, "audio/") ->
        {:ok, track(response.body, mime), nil, built.result_metadata}

      String.contains?(lower, "text/event-stream") ->
        with {:ok, bytes} <- stream_audio(response.body, built.max_audio_bytes, deadline) do
          {:ok, track(bytes, "audio/mpeg"), nil, built.result_metadata}
        end

      true ->
        json_output(response.body, built, deadline)
    end
  end

  defp json_output(body, built, deadline) do
    with {:ok, payload} when is_map(payload) <- Jason.decode(decoded_text(body)),
         :ok <- base_response(payload["base_resp"]) do
      nested = if is_map(payload["data"]), do: payload["data"], else: %{}
      candidate = optional_string(payload["audio"]) || optional_string(nested["audio"])
      candidate_url = is_binary(candidate) and Regex.match?(~r/\Ahttps?:\/\//iu, candidate)

      url =
        optional_string(payload["audio_url"]) || optional_string(nested["audio_url"]) ||
          if(candidate_url, do: candidate, else: nil)

      lyrics = possible_text(payload["lyrics"] || nested["lyrics"] || "")

      metadata =
        built.result_metadata
        |> optional(:task_id, optional_string(payload["task_id"]))
        |> optional(:audio_url, url)

      cond do
        url ->
          with {:ok, response} <- http(:get, url, [], built, deadline, :download),
               :ok <- binary_response(response),
               :ok <- check_deadline(deadline) do
            mime = optional_string(response.mime_type) || "audio/mpeg"
            {:ok, track(response.body, mime), lyrics, metadata}
          end

        candidate ->
          with {:ok, bytes} <- hex(candidate, built.max_audio_bytes) do
            {:ok, track(bytes, "audio/mpeg"), lyrics, metadata}
          end

        true ->
          with {:ok, bytes} <- stream_audio(body, built.max_audio_bytes, deadline) do
            {:ok, track(bytes, "audio/mpeg"), lyrics, metadata}
          end
      end
    else
      {:ok, _} -> {:error, :malformed_response}
      {:error, _} = error -> error
    end
  end

  defp stream_audio(body, cap, deadline) do
    body
    |> decoded_text()
    |> String.split(~r/\r?\n/)
    |> Enum.reduce_while({:ok, [], 0, false}, fn raw, {:ok, chunks, size, completed} ->
      with :ok <- check_deadline(deadline) do
        line = trim(raw)

        if String.starts_with?(line, "data:") do
          json = line |> binary_part(5, byte_size(line) - 5) |> trim()

          if json in ["", "[DONE]"] do
            {:cont, {:ok, chunks, size, completed}}
          else
            with {:ok, frame} when is_map(frame) <- Jason.decode(json),
                 :ok <- base_response(frame["base_resp"]) do
              data = if is_map(frame["data"]), do: frame["data"], else: %{}
              done = data["status"] in [2, 2.0, "2"]
              audio = optional_string(data["audio"])

              if audio && not (done and chunks != []) do
                case hex(audio, cap - size) do
                  {:ok, bytes} ->
                    {:cont, {:ok, [bytes | chunks], size + byte_size(bytes), completed or done}}

                  error ->
                    {:halt, error}
                end
              else
                {:cont, {:ok, chunks, size, completed or done}}
              end
            else
              {:ok, _} -> {:halt, {:error, :malformed_response}}
              {:error, _} = error -> {:halt, error}
            end
          end
        else
          {:cont, {:ok, chunks, size, completed}}
        end
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, chunks, size, true} when size > 0 ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {:ok, _, _, _} ->
        {:error, :incomplete_audio}

      error ->
        error
    end
  end

  defp hex(value, cap) do
    value = trim(value)

    if value != "" and div(byte_size(value), 2) <= cap do
      case Base.decode16(value, case: :mixed) do
        {:ok, bytes} -> {:ok, bytes}
        :error -> {:error, :malformed_audio}
      end
    else
      {:error, :audio_too_large}
    end
  end

  defp possible_text(value) when is_binary(value) do
    value = trim(value)

    if value != "" and rem(byte_size(value), 2) == 0 and Regex.match?(~r/\A[0-9a-f]+\z/iu, value) do
      value |> Base.decode16!(case: :mixed) |> String.replace_invalid() |> trim()
    else
      value
    end
  end

  defp possible_text(_), do: ""

  defp decoded_text(bytes) do
    bytes =
      case bytes do
        <<0xEF, 0xBB, 0xBF, rest::binary>> -> rest
        bytes -> bytes
      end

    String.replace_invalid(bytes)
  end

  defp base_response(%{"status_code" => code}) when is_number(code) and code != 0,
    do: {:error, :provider_response}

  defp base_response(_), do: :ok

  defp track(bytes, mime),
    do: %{data: bytes, mime_type: mime, filename: "track-1." <> extension(mime)}

  @media_content_type ~r/\A[!#$%&'*+.^_`|~\da-z-]+\/[!#$%&'*+.^_`|~\da-z-]+(?:[ \t]*;(?:[ \t]*[!#$%&'*+.^_`|~\da-z-]+[ \t]*=[ \t]*(?:[!#$%&'*+.^_`|~\da-z-]+|"(?:[\t !#-[\]-~\x80-\xff]|\\[\t !-~\x80-\xff])*"))?)*[ \t]*\z/iu
  defp binary_response(response) do
    case response.mime_type do
      nil ->
        if response.body != "", do: :ok, else: {:error, :missing_audio}

      raw ->
        mime = raw |> String.split(";", parts: 2) |> hd() |> trim() |> String.downcase()

        valid_family =
          String.starts_with?(mime, "audio/") or
            mime in ["application/octet-stream", "binary/octet-stream", "application/ogg"]

        if valid_family and Regex.match?(@media_content_type, trim(raw)) and response.body != "",
          do: :ok,
          else: {:error, :malformed_audio}
    end
  end

  defp http(method, url, options, built, deadline, stage) do
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
            into: fn event, pair -> collect(event, pair, built, stage) end,
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

  defp collect({:data, data}, {request, response}, built, stage) do
    {size, chunks} = Req.Response.get_private(response, :minimax_music_body, {0, []})
    mime = optional_string(content_type(response.headers)) || ""

    cap =
      if stage == :download or String.starts_with?(String.downcase(mime), "audio/"),
        do: built.max_audio_bytes,
        else: built.max_response_bytes

    if size + byte_size(data) <= cap do
      {:cont,
       {request,
        Req.Response.put_private(
          response,
          :minimax_music_body,
          {size + byte_size(data), [data | chunks]}
        )}}
    else
      {:halt, {request, Req.Response.put_private(response, :minimax_music_limit, true)}}
    end
  end

  defp response({:ok, response}) do
    cond do
      Req.Response.get_private(response, :minimax_music_limit, false) ->
        {:error, :response_too_large}

      response.status not in 200..299 ->
        {:error, {:http_status, response.status}}

      true ->
        {_, chunks} = Req.Response.get_private(response, :minimax_music_body, {0, []})

        {:ok,
         %{
           body: chunks |> Enum.reverse() |> IO.iodata_to_binary(),
           mime_type: content_type(response.headers)
         }}
    end
  end

  defp response({:error, _}), do: {:error, :transport}

  defp content_type(headers) do
    case Map.get(headers, "content-type", []) do
      [] -> nil
      values -> Enum.join(values, ", ")
    end
  end

  defp optional(map, _key, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)
  defp nonempty?(value), do: value not in [nil, "", %{}, []]
  defp text?(value), do: is_binary(value) and String.valid?(value)
  defp optional_text?(nil), do: true
  defp optional_text?(value), do: text?(value)
  defp positive_integer?(value), do: is_integer(value) and value > 0
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

  defp extension(mime) do
    mime = mime |> String.split(";", parts: 2) |> hd() |> trim() |> String.downcase()
    Map.get(@extensions, Map.get(@mime_aliases, mime, mime), "mp3")
  end
end
