defmodule Synapsis.Provider.ImageGeneration.Google do
  @moduledoc """
  Inactive explicit Google image generation and editing protocol (OpenClaw 488631c).

  Atom-keyed requests require `:prompt`, `:model` and finite positive integer
  `:timeout_ms`. Optional `:size`, `:aspect_ratio` and `:resolution` follow the
  source geometry precedence. Up to five `:input_images` supply already-read
  binary `:data` and raw `:mime_type`; this admission limit is a host boundary,
  not enforcement by the direct source provider. Images precede the exact prompt.
  Input URLs and filenames, count, quality, output format, background and provider
  options are ignored, as in the source. Count never fans out or truncates results.

  Config requires explicit `:api_key` and `:base_url`. Official Google roots
  normalize to v1beta, including the source's terminal /openai normalization.
  Explicit custom roots permit local fixtures; the source restricts its transport
  to the official host. No OpenClaw attribution or credential discovery is copied.
  Omitted model and 180-second timeout defaults remain source-only behavior.

  `:max_image_bytes` defaults to 64 MiB. The default raw JSON budget is
  `ceil(max(64 MiB, max_image_bytes) * 4 * 4 / 3) + 1 MiB`, matching the source
  helper's media floor and declared four results. An explicit positive
  `:max_response_bytes` can tighten that host bound. Every returned image is kept
  in candidate/part order, with a pre-decode per-image byte bound; no MIME sniffing
  occurs. Results contain only `:images` (data, mime_type, filename) and `:model`.

  Call `generate/2` from a supervised execution task. A linked HTTP task uses
  shared Req.Finch with one absolute deadline, bounded raw reads, finite pool/
  request waits and chunk idle waits at most 30 seconds. There are no retries,
  downloads, polling, registration, config lookup, storage, jobs or delivery.
  """

  @max_image_bytes 64 * 1024 * 1024
  @max_timeout 2_147_483_647
  @max_safe_integer 9_007_199_254_740_991
  @chunk_timeout 30_000
  @js_space "[\\x{0009}-\\x{000D}\\x{0020}\\x{00A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}]"
  @js_trim Regex.compile!("\\A#{@js_space}+|#{@js_space}+\\z", "u")
  @aliases %{
    "gemini-3-pro" => "gemini-3.1-pro-preview",
    "gemini-3-pro-preview" => "gemini-3.1-pro-preview",
    "gemini-3-flash" => "gemini-3-flash-preview",
    "gemini-3.1-pro" => "gemini-3.1-pro-preview",
    "gemini-3.1-flash-lite-preview" => "gemini-3.1-flash-lite",
    "gemini-3.1-flash" => "gemini-3-flash-preview",
    "gemini-3.1-flash-preview" => "gemini-3-flash-preview",
    "gemini-4" => "gemini-4-argon",
    "gemma-4-26b" => "gemma-4-26b-a4b-it"
  }
  @aspects %{
    "1024x1024" => "1:1",
    "1024x1536" => "2:3",
    "1536x1024" => "3:2",
    "1024x1792" => "9:16",
    "1792x1024" => "16:9"
  }

  @spec build_request(map(), map()) :: {:ok, map()} | {:error, term()}
  def build_request(request, config) when is_map(request) and is_map(config) do
    with :ok <- validate_request(request),
         :ok <- validate_config(config) do
      model = request.model |> trim() |> normalize_model()
      max_image_bytes = Map.get(config, :max_image_bytes, @max_image_bytes)
      geometry = size_config(request[:size])
      aspect = optional_string(request[:aspect_ratio])
      geometry = if aspect, do: Map.put(geometry, "aspectRatio", aspect), else: geometry
      resolution = request[:resolution]

      geometry =
        if resolution not in [nil, ""],
          do: Map.put(geometry, "imageSize", resolution),
          else: geometry

      parts =
        Enum.map(request[:input_images] || [], fn image ->
          %{"inlineData" => %{"mimeType" => image.mime_type, "data" => Base.encode64(image.data)}}
        end)

      generation = %{"responseModalities" => ["TEXT", "IMAGE"]}

      generation =
        if geometry == %{}, do: generation, else: Map.put(generation, "imageConfig", geometry)

      {:ok,
       %{
         url: base_url(config.base_url) <> "/models/" <> model <> ":generateContent",
         body: %{
           "contents" => [%{"role" => "user", "parts" => parts ++ [%{"text" => request.prompt}]}],
           "generationConfig" => generation
         },
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

      case Task.yield(task, max(0, deadline - now_ms())) || Task.shutdown(task, :brutal_kill) do
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

      not (is_integer(request[:timeout_ms]) and request.timeout_ms > 0 and
               request.timeout_ms <= @max_timeout) ->
        {:error, :invalid_timeout}

      not Enum.all?([:size, :aspect_ratio, :resolution], &optional_text?(request[&1])) ->
        {:error, :invalid_request}

      not is_list(inputs) or length(inputs) > 5 or not Enum.all?(inputs, &input_image?/1) ->
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

  defp input_image?(image) when is_map(image),
    do: is_binary(image[:data]) and text?(image[:mime_type])

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
  defp normalize_model("google/" <> model), do: "google/" <> normalize_model(model)
  defp normalize_model(model), do: Map.get(@aliases, model, model)

  defp base_url(value) do
    uri = value |> trim() |> URI.parse()
    uri = if uri.host, do: %{uri | host: String.downcase(uri.host)}, else: uri
    path = (uri.path || "") |> String.trim_trailing("/")

    path =
      if uri.scheme == "https" and
           String.downcase(uri.host || "") == "generativelanguage.googleapis.com" do
        case Regex.replace(~r/\/openai$/i, path, "") do
          "" -> "/v1beta"
          path -> path
        end
      else
        path
      end

    %{uri | path: path, query: nil, fragment: nil, userinfo: nil}
    |> URI.to_string()
    |> String.trim_trailing("/")
  end

  defp size_config(nil), do: %{}

  defp size_config(size) do
    normalized = size |> trim() |> String.downcase()

    case String.split(normalized, "x") do
      [width, height | _] ->
        with {:ok, width} <- dimension(width), {:ok, height} <- dimension(height) do
          config =
            case @aspects[normalized] do
              nil -> %{}
              aspect -> %{"aspectRatio" => aspect}
            end

          cond do
            max(width, height) >= 3072 -> Map.put(config, "imageSize", "4K")
            max(width, height) >= 1536 -> Map.put(config, "imageSize", "2K")
            true -> config
          end
        else
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp dimension(value) do
    value = trim(value)

    if Regex.match?(~r/\A[+-]?[0-9]+\z/, value) do
      case Integer.parse(value) do
        {number, ""} when number > 0 and number <= @max_safe_integer -> {:ok, number}
        _ -> :error
      end
    else
      :error
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
  defp remaining(deadline), do: max(0, deadline - now_ms())

  defp perform(built, api_key, deadline) do
    with {:ok, body} <- http(built, api_key, deadline),
         :ok <- check_deadline(deadline),
         {:ok, payload} <- decode_payload(body),
         {:ok, images} <- read_images(payload, built.max_image_bytes, deadline),
         :ok <- check_deadline(deadline) do
      {:ok, %{images: images, model: built.model}}
    end
  rescue
    _exception -> {:error, :transport}
  catch
    :exit, _reason -> {:error, :transport}
  end

  defp check_deadline(deadline),
    do: if(remaining(deadline) > 0, do: :ok, else: {:error, :timeout})

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
        json: built.body,
        headers: [{"x-goog-api-key", api_key}],
        raw: true,
        compressed: false,
        into: fn event, pair -> collect(event, pair, built.max_response_bytes) end,
        retry: false,
        redirect: false,
        receive_timeout: min(timeout, @chunk_timeout),
        request_timeout: timeout,
        finch: [pool_timeout: timeout]
      )
      |> Req.request()
      |> response()
    end
  end

  defp collect({:data, data}, {request, response}, limit) do
    {size, chunks} = Req.Response.get_private(response, :google_image_body, {0, []})

    if size + byte_size(data) <= limit do
      {:cont,
       {request,
        Req.Response.put_private(
          response,
          :google_image_body,
          {size + byte_size(data), [data | chunks]}
        )}}
    else
      {:halt, {request, Req.Response.put_private(response, :google_image_limit, true)}}
    end
  end

  defp response({:ok, response}) do
    cond do
      Req.Response.get_private(response, :google_image_limit, false) ->
        {:error, :response_too_large}

      response.status not in 200..299 ->
        {:error, {:http_status, response.status}}

      true ->
        {_size, chunks} = Req.Response.get_private(response, :google_image_body, {0, []})
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  defp response({:error, _reason}), do: {:error, :transport}

  defp decode_payload(<<0xEF, 0xBB, 0xBF, body::binary>>), do: decode_payload(body)

  defp decode_payload(body) do
    case Jason.decode(body) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      _ -> {:error, :malformed_response}
    end
  end

  defp read_images(payload, limit, deadline) do
    with {:ok, candidates} <- optional_list(payload["candidates"]) do
      candidates
      |> Enum.reduce_while({:ok, [], 0}, fn candidate, {:ok, images, index} ->
        with :ok <- check_deadline(deadline),
             {:ok, parts} <- candidate_parts(candidate),
             {:ok, images, index} <- read_parts(parts, images, index, limit, deadline) do
          {:cont, {:ok, images, index}}
        else
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, [], _index} -> {:error, :missing_image_data}
        {:ok, images, _index} -> {:ok, Enum.reverse(images)}
        error -> error
      end
    end
  end

  defp optional_list(nil), do: {:ok, []}
  defp optional_list(value) when is_list(value), do: {:ok, value}
  defp optional_list(_value), do: {:error, :malformed_response}

  defp candidate_parts(candidate) when is_map(candidate) do
    case candidate["content"] do
      nil -> {:ok, []}
      content when is_map(content) -> optional_list(content["parts"])
      _ -> {:error, :malformed_response}
    end
  end

  defp candidate_parts(_candidate), do: {:error, :malformed_response}

  defp read_parts(parts, images, index, limit, deadline) do
    Enum.reduce_while(parts, {:ok, images, index}, fn part, {:ok, images, index} ->
      with :ok <- check_deadline(deadline), {:ok, inline} <- inline_data(part) do
        if is_nil(inline) do
          {:cont, {:ok, images, index}}
        else
          case image(inline, index, limit) do
            {:ok, image} -> {:cont, {:ok, [image | images], index + 1}}
            error -> {:halt, error}
          end
        end
      else
        error -> {:halt, error}
      end
    end)
  end

  defp inline_data(part) when is_map(part) do
    inline = if is_nil(part["inlineData"]), do: part["inline_data"], else: part["inlineData"]
    if is_nil(inline) or is_map(inline), do: {:ok, inline}, else: {:error, :malformed_response}
  end

  defp inline_data(_part), do: {:error, :malformed_response}

  defp image(inline, index, limit) do
    with data when is_binary(data) <- optional_string(inline["data"]),
         {:ok, bytes} <- decode_image(data, limit) do
      mime =
        optional_string(inline["mimeType"]) || optional_string(inline["mime_type"]) || "image/png"

      {:ok, %{data: bytes, mime_type: mime, filename: "image-#{index + 1}." <> extension(mime)}}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :malformed_response}
    end
  end

  defp decode_image(data, limit) do
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
