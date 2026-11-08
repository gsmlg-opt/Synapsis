defmodule Synapsis.Provider.ImageGeneration.OpenAI do
  @moduledoc """
  Inactive explicit OpenAI-compatible image generation and editing protocol.

  Atom-keyed requests require `:prompt`, `:model` and positive `:timeout_ms`.
  Optional fields are `:count` (clamped to 1–4), `:size`, `:quality`,
  `:output_format`, `:background`, up to five `:input_images` containing binary
  `:data` plus optional `:mime_type`/`:filename`, and `:provider_options` with
  an `:openai` map of `:background`, `:moderation`, `:output_compression`/`:user`.

  Config explicitly supplies `:api_key` and versioned `:base_url`. Optional
  `:api_style` selects `:openai` or `:azure`; otherwise Azure hostnames are
  recognized. `:api_version` defaults to `2024-12-01-preview` without environment
  reads. `:max_image_bytes` defaults to 64 MiB and `:max_response_bytes` to
  `ceil(max_image_bytes * count * 4 / 3) + 1 MiB` of raw JSON.

  `build_request/2` returns a JSON or ordered multipart Req plan. Native
  public/Azure geometry and provider options follow OpenClaw 488631c; custom
  endpoints retain requested sizes. Explicit models are retained. The public
  `gpt-image-2` transparent combination returns unsupported: unlike the pinned
  source, this adapter never silently substitutes `gpt-image-1.5`.

  Call `generate/2` from a supervised execution task. One linked HTTP task and
  one finite absolute deadline cover the POST and ordered image downloads,
  including pool checkout and bounded raw bodies. Requests use shared Req.Finch
  without retries; each chunk idle timeout is at most 30s. Downloads use clean
  requests. Results contain image bytes, MIME, filenames, optional revised
  prompts, the selected model and optional string-keyed geometry/usage metadata.

  This module performs no discovery, config lookup, native tool registration,
  file/media storage, task lifecycle, message mutation or delivery activation.
  """

  @max_image_bytes 64 * 1024 * 1024
  @max_timeout 2_147_483_647
  @max_safe_integer 9_007_199_254_740_991
  @chunk_timeout 30_000
  @sizes ~w(1024x1024 1536x1024 1024x1536 2048x2048 2048x1152 3840x2160 2160x3840)
  @legacy_models ~w(gpt-image-1 gpt-image-1-mini)
  @models_25 ~w(gpt-image-2.5-flare gpt-image-2.5-sunburst)
  @flexible_models ["gpt-image-2", "gpt-image-2-2026-04-21" | @models_25]
  @azure_suffixes ~w(.openai.azure.com .services.ai.azure.com .cognitiveservices.azure.com)
  @js_space "[\\x{0009}-\\x{000D}\\x{0020}\\x{00A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}]"
  @js_trim Regex.compile!("\\A#{@js_space}+|#{@js_space}+\\z", "u")
  @upload_extensions %{
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
    "image/gif" => "gif"
  }

  @spec build_request(map(), map()) :: {:ok, map()} | {:error, term()}
  def build_request(request, config) when is_map(request) and is_map(config) do
    with :ok <- validate_request(request),
         :ok <- validate_config(config),
         base_url = config.base_url |> trim() |> String.trim_trailing("/"),
         azure = azure?(base_url, config[:api_style]),
         options = openai_options(request),
         :ok <- supported_model(request.model, base_url, azure, options) do
      count = resolve_count(request[:count])
      inputs = request[:input_images] || []
      action = if inputs == [], do: "generations", else: "edits"

      {size, metadata} =
        resolve_size(request.model, request[:size], azure or public_base?(base_url))

      max_image_bytes = Map.get(config, :max_image_bytes, @max_image_bytes)

      fields =
        if(azure, do: [], else: [{"model", request.model}]) ++
          [{"prompt", request.prompt}, {"n", count}, {"size", size}] ++ options

      built = %{
        url: image_url(base_url, request.model, action, azure, config),
        model: request.model,
        timeout_ms: request.timeout_ms,
        api_style: if(azure, do: :azure, else: :openai),
        max_image_bytes: max_image_bytes,
        max_response_bytes:
          Map.get(
            config,
            :max_response_bytes,
            div(max_image_bytes * count * 4 + 2, 3) + 1024 * 1024
          ),
        output_mime: output_mime(request[:output_format])
      }

      built = if metadata, do: Map.put(built, :metadata, metadata), else: built

      if inputs == [] do
        {:ok, Map.put(built, :body, Map.new(fields))}
      else
        form = Enum.map(fields, fn {name, value} -> {name, to_string(value)} end)
        images = Enum.with_index(inputs, fn image, index -> upload_part(image, index) end)
        {:ok, Map.put(built, :form, form ++ images)}
      end
    end
  end

  def build_request(_request, _config), do: {:error, :invalid_request}

  @spec generate(map(), map()) :: {:ok, map()} | {:error, term()}
  def generate(request, config) do
    with {:ok, built} <- build_request(request, config) do
      deadline = now_ms() + built.timeout_ms
      task = Task.async(fn -> perform(built, config.api_key, deadline) end)

      case Task.yield(task, max(0, deadline - now_ms())) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        nil -> {:error, :timeout}
        {:exit, _reason} -> {:error, :transport}
      end
    end
  end

  defp validate_request(request) do
    inputs = request[:input_images] || []
    options = request[:provider_options] || %{}

    cond do
      not text?(request[:prompt]) or not text?(request[:model]) or request.model == "" ->
        {:error, :invalid_request}

      not (is_integer(request[:timeout_ms]) and request.timeout_ms > 0 and
               request.timeout_ms <= @max_timeout) ->
        {:error, :invalid_timeout}

      not Enum.all?([:size, :quality, :output_format, :background], &optional_text?(request[&1])) ->
        {:error, :invalid_request}

      not is_list(inputs) or length(inputs) > 5 or not Enum.all?(inputs, &input_image?/1) ->
        {:error, :invalid_input_images}

      not is_map(options) or not is_map(Map.get(options, :openai, %{})) ->
        {:error, :invalid_options}

      not valid_options?(Map.get(options, :openai, %{})) ->
        {:error, :invalid_options}

      true ->
        :ok
    end
  end

  defp validate_config(config) do
    cond do
      not text?(config[:api_key]) or config.api_key == "" ->
        {:error, :missing_credentials}

      not text?(config[:base_url]) or trim(config.base_url) == "" ->
        {:error, :invalid_config}

      config[:api_style] not in [nil, :openai, :azure] ->
        {:error, :invalid_config}

      not optional_text?(config[:api_version]) ->
        {:error, :invalid_config}

      not positive_integer?(Map.get(config, :max_image_bytes, @max_image_bytes)) ->
        {:error, :invalid_max_image_bytes}

      Map.has_key?(config, :max_response_bytes) and
          not positive_integer?(config.max_response_bytes) ->
        {:error, :invalid_max_response_bytes}

      true ->
        :ok
    end
  end

  defp text?(value), do: is_binary(value) and String.valid?(value)
  defp optional_text?(nil), do: true
  defp optional_text?(value), do: text?(value)
  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp input_image?(image) when is_map(image) do
    is_binary(image[:data]) and optional_text?(image[:mime_type]) and
      optional_text?(image[:filename])
  end

  defp input_image?(_image), do: false

  defp valid_options?(options) do
    Enum.all?([:background, :moderation, :user], &optional_text?(options[&1])) and
      (is_nil(options[:output_compression]) or is_number(options[:output_compression]))
  end

  defp resolve_count(value) when is_number(value), do: value |> floor() |> max(1) |> min(4)
  defp resolve_count(_value), do: 1

  defp openai_options(request) do
    options = get_in(request, [:provider_options, :openai]) || %{}

    background =
      if is_nil(options[:background]), do: request[:background], else: options.background

    [
      {"quality", request[:quality]},
      {"output_format", request[:output_format]},
      {"background", background},
      {"moderation", options[:moderation]},
      {"output_compression",
       if(request[:output_format] in ["jpeg", "webp"], do: options[:output_compression])},
      {"user", options[:user]}
    ]
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
  end

  defp supported_model("gpt-image-2", base_url, false, options) do
    if public_base?(base_url) and {"background", "transparent"} in options,
      do: {:error, :unsupported_model_background},
      else: :ok
  end

  defp supported_model(_model, _base_url, _azure, _options), do: :ok

  defp azure?(_base_url, :azure), do: true
  defp azure?(_base_url, :openai), do: false

  defp azure?(base_url, nil) do
    host = URI.parse(base_url).host
    is_binary(host) and Enum.any?(@azure_suffixes, &String.ends_with?(String.downcase(host), &1))
  end

  defp public_base?(base_url) do
    uri = URI.parse(base_url)

    uri.scheme == "https" and is_binary(uri.host) and
      String.downcase(uri.host) == "api.openai.com" and uri.port == 443 and
      is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) and
      String.trim_trailing(uri.path || "", "/") == "/v1"
  end

  defp image_url(base_url, _model, action, false, _config), do: base_url <> "/images/" <> action

  defp image_url(base_url, model, action, true, config) do
    base = base_url |> String.replace(~r{/openai/v1$}, "") |> String.replace(~r{/v1$}, "")
    version = optional_string(config[:api_version]) || "2024-12-01-preview"

    base <>
      "/openai/deployments/" <>
      model <> "/images/" <> action <> "?" <> URI.encode_query(%{"api-version" => version})
  end

  defp resolve_size(model, requested_size, native) do
    requested = requested_size || "1024x1024"
    supported = if model in @legacy_models, do: Enum.take(@sizes, 3), else: @sizes

    size =
      if not native or flexible_size?(model, requested),
        do: requested,
        else: closest_size(requested, supported)

    metadata = if size != requested, do: %{"requestedSize" => requested, "normalizedSize" => size}
    {size, metadata}
  end

  defp flexible_size?(model, "auto"), do: model in @models_25

  defp flexible_size?(model, size) when model in @flexible_models do
    case Regex.run(~r/\A(\d+)x(\d+)\z/, size) do
      [_, width, height] ->
        w = String.to_integer(width)
        h = String.to_integer(height)

        w > 0 and h > 0 and rem(w, 16) == 0 and rem(h, 16) == 0 and max(w, h) <= 3840 and
          w * h >= 655_360 and w * h <= 8_294_400 and w <= h * 3 and h <= w * 3

      nil ->
        false
    end
  end

  defp flexible_size?(_model, _size), do: false

  defp closest_size(requested, supported) do
    cond do
      requested in supported ->
        requested

      true ->
        case dimensions(requested) do
          {w, h} ->
            Enum.min_by(supported, fn size ->
              {cw, ch} = dimensions(size)
              {abs(:math.log(cw / ch / (w / h))), abs(:math.log(cw * ch / (w * h))), size}
            end)

          nil ->
            "1024x1024"
        end
    end
  end

  defp dimensions(size) do
    case Regex.run(~r/\A(\d+)\s*x\s*(\d+)\z/i, trim(size)) do
      [_, width, height] ->
        w = String.to_integer(width)
        h = String.to_integer(height)
        if w > 0 and h > 0 and w <= @max_safe_integer and h <= @max_safe_integer, do: {w, h}

      nil ->
        nil
    end
  end

  defp upload_part(image, index) do
    mime = optional_string(image[:mime_type]) || "image/png"

    filename =
      case optional_string(image[:filename]) do
        nil ->
          extension_mime =
            mime |> String.split(";", parts: 2) |> hd() |> trim() |> String.downcase()

          "image-#{index + 1}." <> Map.get(@upload_extensions, extension_mime, "png")

        name ->
          Path.basename(name)
      end

    blob_type =
      if mime |> :binary.bin_to_list() |> Enum.all?(&(&1 in 0x20..0x7E)),
        do: String.downcase(mime, :ascii),
        else: ""

    wire_type = if blob_type == "", do: "application/octet-stream", else: blob_type
    {"image[]", {image.data, filename: filename, content_type: wire_type}}
  end

  defp output_mime("jpeg"), do: "image/jpeg"
  defp output_mime("webp"), do: "image/webp"
  defp output_mime(_format), do: "image/png"

  defp trim(value), do: Regex.replace(@js_trim, value, "")

  defp optional_string(value) when is_binary(value) do
    case trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp optional_string(_value), do: nil
  defp now_ms, do: System.monotonic_time(:millisecond)

  defp perform(built, api_key, deadline) do
    headers =
      if built.api_style == :azure,
        do: [{"api-key", api_key}],
        else: [{"authorization", "Bearer " <> api_key}]

    body =
      case built do
        %{form: form} -> [form_multipart: form]
        %{body: body} -> [json: body]
      end

    with {:ok, response} <-
           http(:post, built.url, [headers: headers] ++ body, built.max_response_bytes, deadline),
         {:ok, payload} <- decode_payload(response.body),
         {:ok, images} <- read_images(payload["data"], built, deadline) do
      metadata = built[:metadata] || %{}
      usage = resolve_usage(payload["usage"])
      metadata = if usage == %{}, do: metadata, else: Map.put(metadata, "usage", usage)
      result = %{images: images, model: built.model}
      {:ok, if(metadata == %{}, do: result, else: Map.put(result, :metadata, metadata))}
    end
  rescue
    _exception -> {:error, :transport}
  catch
    :exit, _reason -> {:error, :transport}
  end

  defp http(method, url, options, limit, deadline) do
    remaining = deadline - now_ms()

    if remaining <= 0 do
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
            receive_timeout: min(remaining, @chunk_timeout),
            request_timeout: remaining,
            finch: [pool_timeout: remaining]
          ]
      )
      |> Req.request()
      |> response()
    end
  end

  defp collect({:data, data}, {request, response}, limit) do
    {size, chunks} = Req.Response.get_private(response, :image_generation_body, {0, []})

    if size + byte_size(data) <= limit do
      {:cont,
       {request,
        Req.Response.put_private(
          response,
          :image_generation_body,
          {size + byte_size(data), [data | chunks]}
        )}}
    else
      {:halt, {request, Req.Response.put_private(response, :image_generation_limit, true)}}
    end
  end

  defp response({:ok, response}) do
    cond do
      Req.Response.get_private(response, :image_generation_limit, false) ->
        {:error, :response_too_large}

      response.status not in 200..299 ->
        {:error, {:http_status, response.status}}

      true ->
        {_size, chunks} = Req.Response.get_private(response, :image_generation_body, {0, []})

        {:ok,
         %{body: chunks |> Enum.reverse() |> IO.iodata_to_binary(), headers: response.headers}}
    end
  end

  defp response({:error, _reason}), do: {:error, :transport}

  defp decode_payload(body) do
    body =
      case body do
        <<0xEF, 0xBB, 0xBF, rest::binary>> -> rest
        body -> body
      end

    case Jason.decode(body) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      _ -> {:error, :malformed_response}
    end
  end

  defp read_images(entries, built, deadline) when is_list(entries) and entries != [] do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], 0}, fn {entry, index}, {:ok, images, downloads} ->
      case read_image(entry, index, built, deadline, downloads) do
        {:ok, image, count} -> {:cont, {:ok, [image | images], count}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, images, _downloads} -> {:ok, Enum.reverse(images)}
      error -> error
    end
  end

  defp read_images(_entries, _built, _deadline), do: {:error, :malformed_response}

  defp read_image(entry, index, built, deadline, downloads) when is_map(entry) do
    case optional_string(entry["b64_json"]) do
      nil ->
        with url when is_binary(url) <- optional_string(entry["url"]),
             true <- downloads < 4,
             {:ok, response} <- http(:get, url, [], built.max_image_bytes, deadline),
             mime when is_binary(mime) <- download_mime(response.headers),
             true <- byte_size(response.body) > 0 do
          {:ok, asset(response.body, mime, entry, index), downloads + 1}
        else
          {:error, reason} -> {:error, reason}
          _ -> {:error, :malformed_response}
        end

      base64 ->
        with {:ok, bytes} <- decode_image(base64, built.max_image_bytes) do
          mime = optional_string(entry["mime_type"]) || built.output_mime
          {:ok, asset(bytes, mime, entry, index), downloads}
        end
    end
  end

  defp read_image(_entry, _index, _built, _deadline, _downloads),
    do: {:error, :malformed_response}

  defp download_mime(headers) do
    case Map.get(headers, "content-type", []) do
      [value | _] ->
        mime = value |> String.split(";", parts: 2) |> hd() |> trim() |> String.downcase()
        if Regex.match?(~r/\Aimage\/[a-z0-9.+-]+\z/, mime), do: mime

      _ ->
        nil
    end
  end

  defp decode_image(base64, limit) do
    cleaned = Regex.replace(~r/[\x00-\x20]/, base64, "")
    remainder = rem(byte_size(cleaned), 4)
    canonical = cleaned <> String.duplicate("=", rem(4 - remainder, 4))

    with true <- cleaned != "" and remainder != 1,
         true <- Regex.match?(~r/\A[A-Za-z0-9+\/]*={0,2}\z/, cleaned),
         true <- remainder == 0 or not String.contains?(cleaned, "="),
         {:ok, bytes} <- Base.decode64(canonical),
         true <- Base.encode64(bytes) == canonical and byte_size(bytes) > 0 do
      if byte_size(bytes) <= limit, do: {:ok, bytes}, else: {:error, :image_too_large}
    else
      _ -> {:error, :malformed_response}
    end
  end

  defp asset(bytes, mime, entry, index) do
    image = %{
      data: bytes,
      mime_type: mime,
      filename: "image-#{index + 1}." <> image_extension(mime)
    }

    case optional_string(entry["revised_prompt"]) do
      nil -> image
      prompt -> Map.put(image, :revised_prompt, prompt)
    end
  end

  defp image_extension(mime) do
    normalized = mime |> String.downcase() |> String.split(";", parts: 2) |> hd() |> trim()

    cond do
      String.contains?(normalized, "jpeg") or String.contains?(normalized, "jpg") ->
        "jpg"

      String.contains?(normalized, "svg") ->
        "svg"

      true ->
        case String.split(normalized, "/", parts: 2) do
          [_type, extension] when extension != "" -> extension
          _ -> "png"
        end
    end
  end

  defp resolve_usage(usage) when is_map(usage) do
    counts = project_counts(usage, ~w(input_tokens output_tokens total_tokens))

    Enum.reduce(~w(input_tokens_details output_tokens_details), counts, fn name, result ->
      details = project_counts(usage[name], ~w(text_tokens image_tokens))
      if details == %{}, do: result, else: Map.put(result, name, details)
    end)
  end

  defp resolve_usage(_usage), do: %{}

  defp project_counts(record, fields) when is_map(record) do
    Enum.reduce(fields, %{}, fn field, result ->
      count = record[field]

      if is_number(count) and count >= 0 and count <= @max_safe_integer and trunc(count) == count,
        do: Map.put(result, field, trunc(count)),
        else: result
    end)
  end

  defp project_counts(_record, _fields), do: %{}
end
