defmodule Synapsis.Provider.ImageGeneration.MicrosoftFoundry do
  @moduledoc """
  Inactive explicit Microsoft Foundry MAI image generation and editing protocol.

  Atom-keyed requests require `:prompt`, `:model` and positive finite
  `:timeout_ms`. Deployment names use JavaScript trimming without prefix removal;
  prompts retain their bytes. Only absent count or one is supported. Generation
  sends model, prompt, width and height; size defaults to 1024x1024 and otherwise
  requires exact WIDTHxHEIGHT, sides at least 768 and at most 1,048,576 pixels.
  Aspect ratio, resolution, quality, output format, background and provider options
  are source-unused. Editing ignores size and sends only model, prompt and image.

  Config explicitly supplies `:api_key` and `:base_url`, optionally `:models` as
  `%{id: deployment, name: model_name}` entries. Exact deployment metadata controls
  MAI admission. Custom deployments can generate without metadata; editing needs
  MAI-Image-2.5 or MAI-Image-2.5-Flash, directly or through matching metadata.
  One input image supplies binary `:data`, optional PNG/JPEG/JPG `:mime_type` and
  optional `:filename`. Names are trimmed with paths retained; fallback names use
  microsoft-foundry-input-1 and the original MIME extension. JPG is sent as JPEG.

  HTTP endpoint origin/path are normalized, dropping query, fragment, trailing
  slashes and any /openai or /anthropic suffix before appending /mai/v1/images.
  Existing /mai/v1 is retained. Optional `:request` supports only string headers,
  merged after api-key. JSON forces Content-Type; multipart removes it for its
  generated boundary. Nonempty other transport overrides return unsupported.
  Environment, saved credentials and dynamic Entra authentication are not resolved.

  `:max_image_bytes` defaults to 64 MiB; raw JSON defaults to
  ceil(max(64 MiB, max_image_bytes) * 4 / 3) + 1 MiB, with an optional explicit
  `:max_response_bytes` override. Inline bytes are bounded before decoding. All
  ordered inline images are retained; URL download is not supported by this
  source parser. Explicit MIME wins, otherwise JPEG/PNG/WebP are sniffed with PNG
  fallback. Output names use microsoft-foundry-image and revised prompts trim.

  Call `generate/2` from a supervised execution task. One linked HTTP owner and
  one finite absolute deadline cover the POST using shared Req.Finch, bounded raw
  bodies and no retries or polling. No catalog, defaults, saved config, native
  tools, custody, jobs, storage or delivery activation is performed.
  """

  @max_image_bytes 64 * 1024 * 1024
  @max_timeout 2_147_483_647
  @chunk_timeout 30_000
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
  @mai_models ~w(mai-image-2.5-flash mai-image-2.5 mai-image-2e mai-image-2 mai-image-2-efficient)

  @spec build_request(map(), map()) :: {:ok, map()} | {:error, term()}
  def build_request(request, config) when is_map(request) and is_map(config) do
    with :ok <- validate_request(request),
         :ok <- validate_config(config),
         :ok <- validate_model(request, config),
         {:ok, endpoint} <- endpoint(config.base_url),
         {:ok, headers} <- configured_headers(config) do
      model = trim(request.model)
      inputs = request[:input_images] || []
      max_image_bytes = Map.get(config, :max_image_bytes, @max_image_bytes)
      action = if inputs == [], do: "generations", else: "edits"

      built = %{
        url: endpoint <> "/mai/v1/images/" <> action,
        model: model,
        headers: headers,
        timeout_ms: request.timeout_ms,
        max_image_bytes: max_image_bytes,
        max_response_bytes:
          Map.get(
            config,
            :max_response_bytes,
            div(max(@max_image_bytes, max_image_bytes) * 4 + 2, 3) + 1024 * 1024
          )
      }

      case inputs do
        [] ->
          with {:ok, width, height} <- image_size(request[:size]) do
            {:ok,
             built
             |> Map.put(:body, %{
               "model" => model,
               "prompt" => request.prompt,
               "width" => width,
               "height" => height
             })
             |> Map.update!(:headers, &Map.put(&1, "content-type", "application/json"))}
          end

        [image] ->
          {:ok,
           built
           |> Map.put(:form, [{"model", model}, {"prompt", request.prompt}, upload_part(image)])
           |> Map.update!(:headers, &Map.delete(&1, "content-type"))}
      end
    end
  end

  def build_request(_request, _config), do: {:error, :invalid_request}

  @spec generate(map(), map()) :: {:ok, map()} | {:error, term()}
  def generate(request, config) do
    with {:ok, built} <- build_request(request, config) do
      deadline = now_ms() + built.timeout_ms
      task = Task.async(fn -> perform(built, deadline) end)

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

      Map.has_key?(request, :count) and request.count != 1 ->
        {:error, :invalid_count}

      not optional_text?(request[:size]) ->
        {:error, :invalid_request}

      not is_list(inputs) or length(inputs) > 1 or not Enum.all?(inputs, &input_image?/1) ->
        {:error, :invalid_input_images}

      true ->
        :ok
    end
  end

  defp validate_config(config) do
    cond do
      not text?(config[:api_key]) or config.api_key == "" ->
        {:error, :missing_credentials}

      config.api_key == "__entra_id_dynamic__" ->
        {:error, :unsupported_auth}

      not text?(config[:base_url]) or trim(config.base_url) == "" ->
        {:error, :invalid_config}

      not configured_models?(Map.get(config, :models, [])) ->
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

  defp configured_models?(models) when is_list(models) do
    Enum.all?(models, fn
      %{id: id, name: name} -> text?(id) and text?(name)
      _ -> false
    end)
  end

  defp configured_models?(_models), do: false

  defp validate_model(request, config) do
    model = trim(request.model)
    configured = Enum.find(config[:models] || [], &(&1.id == model))
    configured_name = if configured, do: configured.name
    model_name = if configured_name in [nil, ""], do: model, else: configured_name
    normalized = String.downcase(model)
    has_metadata = configured_name not in [nil, ""] and lower(configured_name) != normalized
    editing = (request[:input_images] || []) != []

    cond do
      not mai_model?(model_name) and
          (has_metadata or
             (String.starts_with?(normalized, "mai-") and
                not String.starts_with?(normalized, "mai-image-"))) ->
        {:error, :unsupported_model}

      editing and (has_metadata or mai_model?(model)) and
          lower(model_name) not in ["mai-image-2.5", "mai-image-2.5-flash"] ->
        {:error, :unsupported_edit_model}

      editing and not has_metadata and not mai_model?(model) ->
        {:error, :unsupported_edit_model}

      true ->
        :ok
    end
  end

  defp mai_model?(model), do: lower(model) in @mai_models
  defp lower(value), do: value |> trim() |> String.downcase()

  defp endpoint(base_url) do
    with {:ok, uri} <- URI.new(trim(base_url)),
         scheme when scheme in ["http", "https"] <- String.downcase(uri.scheme || ""),
         host when is_binary(host) and host != "" <- uri.host do
      path =
        (uri.path || "/")
        |> normalize_path()
        |> String.replace(~r/\/(?:openai|anthropic)(?:$|\/).*/i, "")
        |> String.trim_trailing("/")
        |> URI.encode(fn char ->
          char in 0x21..0x7E and char not in [?", ?#, ?<, ?>, ??, ?`, ?{, ?}]
        end)

      origin = %URI{
        scheme: scheme,
        host: String.downcase(host),
        port: uri.port || URI.default_port(scheme)
      }

      {:ok, URI.to_string(origin) <> path}
    else
      _ -> {:error, :invalid_config}
    end
  end

  defp normalize_path(path) do
    path
    |> String.split("/")
    |> Enum.reduce([], fn
      ".", acc -> acc
      "..", [_last | rest] -> rest
      "..", [] -> []
      segment, acc -> [segment | acc]
    end)
    |> Enum.reverse()
    |> Enum.join("/")
    |> then(fn path -> if String.starts_with?(path, "/"), do: path, else: "/" <> path end)
  end

  defp image_size(size) when size in [nil, ""], do: {:ok, 1024, 1024}

  defp image_size(size) do
    case Regex.run(~r/\A([0-9]{1,5})x([0-9]{1,5})\z/, size) do
      [_, width, height] ->
        width = String.to_integer(width)
        height = String.to_integer(height)

        if width >= 768 and height >= 768 and width * height <= 1_048_576,
          do: {:ok, width, height},
          else: {:error, :invalid_size}

      _ ->
        {:error, :invalid_size}
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
            %{"api-key" => config.api_key},
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

  defp header_map?(headers) when is_map(headers) do
    Enum.all?(headers, fn {name, value} ->
      text?(name) and Regex.match?(~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/, trim(name)) and
        text?(value) and not String.contains?(value, ["\r", "\n", <<0>>])
    end)
  end

  defp header_map?(_headers), do: false
  defp nonempty?(value), do: value not in [nil, "", [], %{}]

  defp input_image?(image) when is_map(image) do
    is_binary(image[:data]) and optional_text?(image[:mime_type]) and
      optional_text?(image[:filename]) and
      lower(optional_string(image[:mime_type]) || "image/png") in [
        "image/png",
        "image/jpeg",
        "image/jpg"
      ]
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

  defp upload_part(image) do
    original_mime = optional_string(image[:mime_type]) || "image/png"
    mime = lower(original_mime)
    wire_mime = if mime == "image/jpg", do: "image/jpeg", else: mime

    filename =
      optional_string(image[:filename]) ||
        "microsoft-foundry-input-1." <> extension(original_mime)

    {"image", {image.data, filename: filename, content_type: wire_mime}}
  end

  defp sniff_mime(<<255, 216, 255, _rest::binary>>), do: "image/jpeg"

  defp sniff_mime(<<137, 80, 78, 71, _rest::binary>> = bytes) when byte_size(bytes) >= 8,
    do: "image/png"

  defp sniff_mime(
         <<riff::binary-size(4), _size::binary-size(4), webp::binary-size(4), _rest::binary>>
       ) do
    if node_ascii(riff) == "RIFF" and node_ascii(webp) == "WEBP",
      do: "image/webp",
      else: "image/png"
  end

  defp sniff_mime(_bytes), do: "image/png"
  defp node_ascii(bytes), do: for(<<byte <- bytes>>, into: <<>>, do: <<Bitwise.band(byte, 0x7F)>>)
  defp now_ms, do: System.monotonic_time(:millisecond)
  defp remaining(deadline), do: max(0, deadline - now_ms())

  defp check_deadline(deadline),
    do: if(remaining(deadline) > 0, do: :ok, else: {:error, :timeout})

  defp perform(built, deadline) do
    body =
      case built do
        %{form: form} -> [form_multipart: form]
        %{body: body} -> [json: body]
      end

    with {:ok, response} <-
           http(
             :post,
             built.url,
             [headers: built.headers] ++ body,
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
    {size, chunks} = Req.Response.get_private(response, :microsoft_foundry_image_body, {0, []})

    if size + byte_size(data) <= limit do
      {:cont,
       {request,
        Req.Response.put_private(
          response,
          :microsoft_foundry_image_body,
          {size + byte_size(data), [data | chunks]}
        )}}
    else
      {:halt, {request, Req.Response.put_private(response, :microsoft_foundry_image_limit, true)}}
    end
  end

  defp response({:ok, response}) do
    cond do
      Req.Response.get_private(response, :microsoft_foundry_image_limit, false) ->
        {:error, :response_too_large}

      response.status not in 200..299 ->
        {:error, {:http_status, response.status}}

      true ->
        {_size, chunks} =
          Req.Response.get_private(response, :microsoft_foundry_image_body, {0, []})

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
    |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, images} ->
      with :ok <- check_deadline(deadline),
           {:ok, image} <- read_image(entry, index, built.max_image_bytes) do
        {:cont, {:ok, [image | images]}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, images} -> {:ok, Enum.reverse(images)}
      error -> error
    end
  end

  defp read_images(_entries, _built, _deadline), do: {:error, :malformed_response}

  defp read_image(entry, index, limit) when is_map(entry) do
    with base64 when is_binary(base64) <- optional_string(entry["b64_json"]),
         {:ok, bytes} <- decode_image(base64, limit) do
      mime = optional_string(entry["mime_type"]) || sniff_mime(bytes)
      {:ok, asset(bytes, mime, entry, index)}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :malformed_response}
    end
  end

  defp read_image(_entry, _index, _limit), do: {:error, :malformed_response}

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
    image = %{
      data: bytes,
      mime_type: mime,
      filename: "microsoft-foundry-image-#{index + 1}." <> extension(mime)
    }

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
