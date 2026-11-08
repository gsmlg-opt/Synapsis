defmodule Synapsis.Provider.ImageGeneration.XAI do
  @moduledoc """
  Inactive explicit xAI image generation and editing protocol.

  Atom-keyed requests require `:prompt`, `:model` and positive finite
  `:timeout_ms`. Optional `:count` is a positive integer (default one, sent at
  most four). Supported `:aspect_ratio` values are sent after trimming;
  `:resolution` is trimmed and lowercased. Size, quality, output format,
  background and provider options are ignored by the pinned xAI callback.

  Up to three ordered `:input_images` select JSON edits: a trimmed `:url` wins,
  otherwise exact binary `:data` becomes a data URL with trimmed `:mime_type`
  or image/png. One input uses `image`; multiple inputs use `images`.
  Explicit model names are trimmed without aliases or default selection.

  Config explicitly supplies `:api_key` and versioned `:base_url`.
  `:max_image_bytes` defaults to 64 MiB. The default raw JSON limit is
  `ceil(max(64 MiB, max_image_bytes) * 4 * 4 / 3) + 1 MiB`, independently of
  requested count; `:max_response_bytes` can explicitly override it. The
  predecode inline-image bound is a host adaptation to the pinned source.

  Call `generate/2` from a supervised execution task. One linked HTTP owner
  and one absolute deadline cover the POST and at most four sequential URL
  downloads through shared Req.Finch, with bounded bodies and no retries or
  polling. All ordered inline results are retained. MIME is explicit or PNG
  for inline entries, and the lowercased Content-Type base for downloads.
  Results contain only images and the selected model.

  This module performs no discovery, environment/config lookup, tool or model
  registration, media storage, durable job lifecycle or delivery activation.
  """

  @max_image_bytes 64 * 1024 * 1024
  @max_timeout 2_147_483_647
  @chunk_timeout 30_000
  @aspects ~w(1:1 16:9 9:16 4:3 3:4 3:2 2:3 2:1 1:2 19.5:9 9:19.5 20:9 9:20)
  @js_space "[\\x{0009}-\\x{000D}\\x{0020}\\x{00A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}]"
  @js_trim Regex.compile!("\\A#{@js_space}+|#{@js_space}+\\z", "u")

  @spec build_request(map(), map()) :: {:ok, map()} | {:error, term()}
  def build_request(request, config) when is_map(request) and is_map(config) do
    with :ok <- validate_request(request),
         :ok <- validate_config(config) do
      model = trim(request.model)
      inputs = request[:input_images] || []
      max_image_bytes = Map.get(config, :max_image_bytes, @max_image_bytes)
      action = if inputs == [], do: "generations", else: "edits"

      body = %{
        "model" => model,
        "prompt" => request.prompt,
        "n" => min(request[:count] || 1, 4),
        "response_format" => "b64_json"
      }

      aspect = optional_string(request[:aspect_ratio])
      body = if aspect in @aspects, do: Map.put(body, "aspect_ratio", aspect), else: body
      resolution = optional_string(request[:resolution])

      body =
        if resolution,
          do: Map.put(body, "resolution", String.downcase(resolution)),
          else: body

      body =
        case Enum.map(inputs, &image_source/1) do
          [] -> body
          [image] -> Map.put(body, "image", image)
          images -> Map.put(body, "images", images)
        end

      {:ok,
       %{
         url:
           trim(config.base_url) |> String.trim_trailing("/") |> Kernel.<>("/images/" <> action),
         body: body,
         model: model,
         timeout_ms: request.timeout_ms,
         max_image_bytes: max_image_bytes,
         max_response_bytes:
           Map.get(
             config,
             :max_response_bytes,
             div(max(@max_image_bytes, max_image_bytes) * 4 * 4 + 2, 3) + 1024 * 1024
           )
       }}
    end
  end

  def build_request(_request, _config), do: {:error, :invalid_request}

  @spec generate(map(), map()) :: {:ok, map()} | {:error, term()}
  def generate(request, config) do
    with {:ok, built} <- build_request(request, config) do
      deadline = now_ms() + built.timeout_ms
      task = Task.async(fn -> perform(built, config.api_key, deadline) end)

      case Task.yield(task, remaining(deadline)) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        nil -> {:error, :timeout}
        {:exit, _reason} -> {:error, :transport}
      end
    end
  end

  defp validate_request(request) do
    inputs = request[:input_images] || []

    cond do
      not text?(request[:prompt]) or not text?(request[:model]) ->
        {:error, :invalid_request}

      trim(request.model) == "" ->
        {:error, :invalid_request}

      not (positive_integer?(request[:timeout_ms]) and request.timeout_ms <= @max_timeout) ->
        {:error, :invalid_timeout}

      not is_nil(request[:count]) and not positive_integer?(request.count) ->
        {:error, :invalid_count}

      not Enum.all?([:aspect_ratio, :resolution], &optional_text?(request[&1])) ->
        {:error, :invalid_request}

      not is_list(inputs) or length(inputs) > 3 or not Enum.all?(inputs, &input_image?/1) ->
        {:error, :invalid_input_images}

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

      not positive_integer?(Map.get(config, :max_image_bytes, @max_image_bytes)) ->
        {:error, :invalid_max_image_bytes}

      Map.has_key?(config, :max_response_bytes) and
          not positive_integer?(config.max_response_bytes) ->
        {:error, :invalid_max_response_bytes}

      true ->
        :ok
    end
  end

  defp input_image?(image) when is_map(image) do
    optional_text?(image[:url]) and optional_text?(image[:mime_type]) and
      (is_binary(optional_string(image[:url])) or is_binary(image[:data]))
  end

  defp input_image?(_image), do: false
  defp text?(value), do: is_binary(value) and String.valid?(value)
  defp optional_text?(nil), do: true
  defp optional_text?(value), do: text?(value)
  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp trim(value), do: Regex.replace(@js_trim, value, "")

  defp optional_string(value) when is_binary(value) do
    case trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp optional_string(_value), do: nil

  defp image_source(image) do
    url =
      optional_string(image[:url]) ||
        "data:" <>
          (optional_string(image[:mime_type]) || "image/png") <>
          ";base64," <> Base.encode64(image.data)

    %{"url" => url, "type" => "image_url"}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
  defp remaining(deadline), do: max(0, deadline - now_ms())

  defp check_deadline(deadline),
    do: if(remaining(deadline) > 0, do: :ok, else: {:error, :timeout})

  defp perform(built, api_key, deadline) do
    with {:ok, response} <-
           http(
             :post,
             built.url,
             [json: built.body, headers: [{"authorization", "Bearer " <> api_key}]],
             built.max_response_bytes,
             deadline
           ),
         :ok <- check_deadline(deadline),
         {:ok, payload} <- decode_payload(response.body),
         {:ok, images} <- read_images(payload["data"], built, deadline),
         :ok <- check_deadline(deadline) do
      {:ok, %{images: images, model: built.model}}
    end
  rescue
    _exception -> {:error, :transport}
  catch
    :exit, _reason -> {:error, :transport}
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
            receive_timeout: min(timeout, @chunk_timeout),
            request_timeout: timeout,
            finch: [pool_timeout: timeout]
          ]
      )
      |> Req.request()
      |> response()
    end
  end

  defp collect({:data, data}, {request, response}, limit) do
    {size, chunks} = Req.Response.get_private(response, :xai_image_body, {0, []})

    if size + byte_size(data) <= limit do
      {:cont,
       {request,
        Req.Response.put_private(
          response,
          :xai_image_body,
          {size + byte_size(data), [data | chunks]}
        )}}
    else
      {:halt, {request, Req.Response.put_private(response, :xai_image_limit, true)}}
    end
  end

  defp response({:ok, response}) do
    cond do
      Req.Response.get_private(response, :xai_image_limit, false) ->
        {:error, :response_too_large}

      response.status not in 200..299 ->
        {:error, {:http_status, response.status}}

      true ->
        {_size, chunks} = Req.Response.get_private(response, :xai_image_body, {0, []})

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
      with :ok <- check_deadline(deadline),
           {:ok, image, count} <- read_image(entry, index, built, deadline, downloads) do
        {:cont, {:ok, [image | images], count}}
      else
        error -> {:halt, error}
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
          {:error, _reason} = error -> error
          _ -> {:error, :malformed_response}
        end

      base64 ->
        with {:ok, bytes} <- decode_image(base64, built.max_image_bytes) do
          mime = optional_string(entry["mime_type"]) || "image/png"
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

  defp decode_image(data, limit) do
    cleaned = Regex.replace(~r/[\x00-\x20]/, data, "")
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
      decoded_size > limit ->
        {:error, :image_too_large}

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

  defp asset(bytes, mime, entry, index) do
    image = %{data: bytes, mime_type: mime, filename: "image-#{index + 1}." <> extension(mime)}

    case optional_string(entry["revised_prompt"]) do
      nil -> image
      prompt -> Map.put(image, :revised_prompt, prompt)
    end
  end

  defp extension(mime) do
    normalized = mime |> String.downcase() |> String.split(";", parts: 2) |> hd() |> trim()

    cond do
      String.contains?(normalized, ["jpeg", "jpg"]) ->
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
end
