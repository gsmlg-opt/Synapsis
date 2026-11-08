defmodule Synapsis.Provider.ImageGeneration.Vydra do
  @moduledoc """
  Inactive, explicit Vydra text-to-image callback protocol (OpenClaw 488631c).

  Atom-keyed requests supply exact UTF-8 `:prompt`, explicit nonblank `:model`
  and finite positive `:timeout_ms`. The model is JavaScript-trimmed for the
  route and result; the JSON body is only prompt and model=text-to-image.
  Input images are unsupported and count may be at most one. Geometry, quality,
  output format, background and provider options do not alter the callback.

  Config supplies explicit `:base_url` and `:api_key`, optional string headers
  in `:headers`, and optional positive `:max_image_bytes` with a 64 MiB floor.
  Source base normalization rewrites vydra.ai to www.vydra.ai, strips trailing
  path slashes and supplies /api/v1 for a root path. JSON is capped at 16 MiB.
  The first source-ordered recursive HTTP(S) URL is downloaded, retaining bytes,
  full trimmed MIME (default image/png), and its MIME-derived image-1 filename.
  Metadata uses atom snake_case job_id/image_url/status; absent job_id is omitted.

  Call `generate/2` from a supervised execution task. One linked HTTP owner uses
  shared Req.Finch. Submission, polling and download each receive a fresh finite
  budget; this image callback does not use the video's aggregate deadline.
  Polling reads immediately, waits 2500 ms after a pending result, and allows
  120 reads. Poll HTTP calls are capped at 120 seconds and remaining poll time.
  Every local HTTP read also has a finite stage deadline; submission JSON has
  a host total bound in addition to the source's 30 second chunk idle bound.

  An outer three-budget watchdog bounds HTTP ownership; segmented finite waits
  support the full timer range without overflowing a single wait. These host
  ownership bounds and transport are not exact source failure/retry/cancellation
  equivalence. Normal caller exit does not guarantee linked-owner cleanup, and
  local cleanup does not establish remote cancellation. No saved configuration,
  environment lookup, registration, native tool, jobs, storage or delivery runs.
  """

  @default_base "https://www.vydra.ai/api/v1"
  @max_response_bytes 16 * 1024 * 1024
  @max_image_bytes 64 * 1024 * 1024
  @max_timeout 2_147_000_000
  @chunk_timeout 30_000
  @poll_http_timeout 120_000
  @poll_interval 2_500
  @poll_attempts 120
  @url_keys ~w(imageUrl imageUrls resultUrl resultUrls outputUrl outputUrls url urls)
  @recurse_keys ~w(output outputs result results data asset assets)
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
         {:ok, headers} <- configured_headers(config) do
      base = normalize_base(config.base_url)
      model = optional_string(request.model)

      {:ok,
       %{
         url: base <> "/models/" <> model,
         base_url: base,
         model: model,
         body: %{"prompt" => request.prompt, "model" => "text-to-image"},
         headers: headers,
         timeout_ms: timer_ms(request.timeout_ms),
         max_response_bytes: @max_response_bytes,
         max_image_bytes:
           max(@max_image_bytes, floor(config[:max_image_bytes] || @max_image_bytes))
       }}
    end
  end

  def build_request(_request, _config), do: {:error, :invalid_request}

  @spec generate(map(), map()) :: {:ok, map()} | {:error, term()}
  def generate(request, config) do
    with {:ok, built} <- build_request(request, config) do
      watchdog = now_ms() + 3 * built.timeout_ms
      task = Task.async(fn -> perform(built) end)
      await_owner(task, watchdog)
    end
  end

  defp await_owner(task, deadline) do
    case Task.yield(task, min(remaining(deadline), @max_timeout)) do
      {:ok, result} ->
        result

      {:exit, _reason} ->
        {:error, :transport}

      nil ->
        if remaining(deadline) > 0 do
          await_owner(task, deadline)
        else
          Task.shutdown(task, :brutal_kill)
          {:error, :timeout}
        end
    end
  end

  defp validate_request(request) do
    cond do
      not text?(request[:prompt]) or is_nil(optional_string(request[:model])) ->
        {:error, :invalid_request}

      not positive_number?(request[:timeout_ms]) ->
        {:error, :invalid_timeout}

      (request[:input_images] || []) != [] ->
        {:error, :unsupported_inputs}

      not is_nil(request[:count]) and
          (not is_number(request.count) or request.count > 1) ->
        {:error, :invalid_count}

      true ->
        :ok
    end
  end

  defp validate_config(config) do
    cond do
      is_nil(optional_string(config[:api_key])) ->
        {:error, :missing_credentials}

      is_nil(optional_string(config[:base_url])) ->
        {:error, :invalid_config}

      not positive_number?(config[:max_image_bytes] || @max_image_bytes) ->
        {:error, :invalid_max_image_bytes}

      true ->
        :ok
    end
  end

  defp configured_headers(config) do
    headers = config[:headers] || %{}

    if is_map(headers) and
         Enum.all?(headers, fn {name, value} ->
           text?(name) and Regex.match?(~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/, trim(name)) and
             text?(value) and not String.contains?(value, ["\r", "\n", <<0>>])
         end) do
      defaults = %{
        "authorization" => "Bearer " <> config.api_key,
        "content-type" => "application/json"
      }

      {:ok,
       Enum.reduce(headers, defaults, fn {name, value}, acc ->
         case optional_string(value) do
           nil -> acc
           value -> Map.put(acc, name |> trim() |> String.downcase(:ascii), value)
         end
       end)}
    else
      {:error, :invalid_headers}
    end
  end

  defp normalize_base(value) do
    case URI.new(trim(value)) do
      {:ok, %URI{scheme: scheme, host: host} = uri} when is_binary(scheme) and is_binary(host) ->
        path = String.trim_trailing(uri.path || "", "/")
        host = String.downcase(host)

        %{
          uri
          | scheme: String.downcase(scheme),
            host: if(host == "vydra.ai", do: "www.vydra.ai", else: host),
            path: if(path == "", do: "/api/v1", else: path)
        }
        |> URI.to_string()
        |> String.trim_trailing("/")

      _ ->
        @default_base
    end
  end

  defp text?(value), do: is_binary(value) and String.valid?(value)
  defp positive_number?(value), do: is_number(value) and value > 0
  defp trim(value), do: Regex.replace(@js_trim, value, "")

  defp optional_string(value) when is_binary(value) do
    if String.valid?(value) do
      case trim(value) do
        "" -> nil
        value -> value
      end
    end
  end

  defp optional_string(_value), do: nil
  defp timer_ms(value), do: value |> floor() |> max(1) |> min(@max_timeout)
  defp now_ms, do: System.monotonic_time(:millisecond)
  defp remaining(deadline), do: max(0, deadline - now_ms())

  defp perform(built) do
    submit_deadline = now_ms() + built.timeout_ms

    with {:ok, submitted} <-
           read_json(
             :post,
             built.url,
             built.headers,
             [body: Jason.encode!(built.body)],
             submit_deadline,
             built.timeout_ms
           ),
         {:ok, completed} <- complete_submission(submitted, built),
         url when is_binary(url) <- first_url(completed),
         {:ok, image} <- download(url, built) do
      metadata = %{image_url: url, status: status(completed) || "completed"}
      id = job_id(completed) || job_id(submitted)
      metadata = if id, do: Map.put(metadata, :job_id, id), else: metadata
      {:ok, %{model: built.model, images: [image], metadata: metadata}}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :malformed_response}
    end
  end

  defp complete_submission(submitted, built) do
    if complete?(submitted) do
      {:ok, submitted}
    else
      case job_id(submitted) do
        nil -> {:error, :missing_job_id}
        id -> poll(built, id, now_ms() + built.timeout_ms, @poll_attempts)
      end
    end
  end

  defp poll(_built, _id, _deadline, 0), do: {:error, :timeout}

  defp poll(built, id, deadline, attempts) do
    with {:ok, payload} when is_map(payload) <-
           read_json(
             :get,
             built.base_url <> "/jobs/" <> id,
             built.headers,
             [],
             deadline,
             @poll_http_timeout
           ) do
      cond do
        complete?(payload) ->
          {:ok, payload}

        status(payload) in ["failed", "error", "cancelled"] ->
          {:error, :generation_failed}

        remaining(deadline) == 0 ->
          {:error, :timeout}

        true ->
          Process.sleep(min(@poll_interval, remaining(deadline)))
          poll(built, id, deadline, attempts - 1)
      end
    else
      {:error, _reason} = error -> error
      _ -> {:error, :malformed_response}
    end
  end

  defp field(payload, key) when is_map(payload), do: payload[key]
  defp field(_payload, _key), do: nil

  defp job_id(payload),
    do: optional_string(field(payload, "jobId")) || optional_string(field(payload, "id"))

  defp status(payload) do
    case optional_string(field(payload, "status")) do
      nil -> nil
      value -> String.downcase(value)
    end
  end

  defp complete?(payload), do: status(payload) == "completed" or not is_nil(first_url(payload))
  defp first_url(payload), do: visit(payload, 0)
  defp visit(_value, depth) when depth > 5, do: nil

  defp visit(values, depth) when is_list(values),
    do: Enum.find_value(values, &visit(&1, depth + 1))

  defp visit(value, depth) when is_map(value) do
    Enum.find_value(@url_keys, &url_value(value[&1])) ||
      Enum.find_value(@recurse_keys, &visit(value[&1], depth + 1))
  end

  defp visit(_value, _depth), do: nil
  defp url_value(values) when is_list(values), do: Enum.find_value(values, &url_value/1)

  defp url_value(value) do
    case optional_string(value) do
      nil -> nil
      url -> if Regex.match?(~r/\Ahttps?:\/\//iu, url), do: url
    end
  end

  defp download(url, built) do
    headers = if origin(url) == origin(built.base_url), do: built.headers, else: %{}
    deadline = now_ms() + built.timeout_ms

    with {:ok, response} <-
           http(
             :get,
             url,
             headers,
             [],
             built.max_image_bytes,
             :binary,
             deadline,
             built.timeout_ms
           ),
         mime =
           response.headers |> Map.get("content-type", []) |> Enum.join(", ") |> optional_string(),
         :ok <- binary_content(response.body, mime) do
      mime = mime || "image/png"
      {:ok, %{data: response.body, mime_type: mime, filename: "image-1." <> extension(mime)}}
    end
  end

  defp origin(url) do
    uri = URI.parse(url)
    {String.downcase(uri.scheme || ""), String.downcase(uri.host || ""), uri.port}
  end

  defp extension(mime) do
    normalized = mime |> String.split(";", parts: 2) |> hd() |> trim() |> String.downcase()
    Map.get(@extensions, Map.get(@mime_aliases, normalized, normalized), "png")
  end

  defp binary_content(<<>>, _mime), do: {:error, :malformed_response}
  defp binary_content(_body, nil), do: :ok

  defp binary_content(_body, mime) do
    normalized = mime |> String.split(";", parts: 2) |> hd() |> trim() |> String.downcase()

    if normalized == "application/json" or String.ends_with?(normalized, "+json") or
         String.starts_with?(normalized, "text/"),
       do: {:error, :malformed_response},
       else: :ok
  end

  defp read_json(method, url, headers, options, deadline, cap) do
    with {:ok, response} <-
           http(method, url, headers, options, @max_response_bytes, :json, deadline, cap) do
      body =
        case response.body do
          <<0xEF, 0xBB, 0xBF, rest::binary>> -> rest
          body -> body
        end

      if String.valid?(body), do: Jason.decode(body), else: {:error, :malformed_response}
    end
  end

  defp http(method, url, headers, options, limit, kind, deadline, cap) do
    case min(remaining(deadline), cap) do
      0 ->
        {:error, :timeout}

      timeout ->
        Req.new(
          options ++
            [
              method: method,
              url: url,
              headers: headers,
              raw: true,
              compressed: false,
              into: fn event, pair -> collect(event, pair, limit) end,
              retry: false,
              redirect: false,
              receive_timeout: if(kind == :json, do: min(timeout, @chunk_timeout), else: timeout),
              request_timeout: timeout,
              finch: [pool_timeout: timeout]
            ]
        )
        |> Req.request()
        |> response()
    end
  end

  defp collect({:data, data}, {request, response}, limit) do
    {size, chunks} = Req.Response.get_private(response, :vydra_image_body, {0, []})

    if size + byte_size(data) <= limit do
      {:cont,
       {request,
        Req.Response.put_private(
          response,
          :vydra_image_body,
          {size + byte_size(data), [data | chunks]}
        )}}
    else
      {:halt, {request, Req.Response.put_private(response, :vydra_image_limit, true)}}
    end
  end

  defp response({:ok, response}) do
    cond do
      Req.Response.get_private(response, :vydra_image_limit, false) ->
        {:error, :response_too_large}

      response.status not in 200..299 ->
        {:error, {:http_status, response.status}}

      true ->
        {_size, chunks} = Req.Response.get_private(response, :vydra_image_body, {0, []})

        {:ok,
         %{body: chunks |> Enum.reverse() |> IO.iodata_to_binary(), headers: response.headers}}
    end
  end

  defp response({:error, _reason}), do: {:error, :transport}
end
