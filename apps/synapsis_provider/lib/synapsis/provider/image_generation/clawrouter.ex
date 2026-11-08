defmodule Synapsis.Provider.ImageGeneration.ClawRouter do
  @moduledoc """
  Inactive explicit ClawRouter JSON image generation protocol.

  Atom-keyed requests require `:prompt`, an exact qualified flare/sunburst
  `:model`, and finite positive `:timeout_ms`. Count defaults to one and must
  be an integer from one to ten. Input images are unsupported. Optional size,
  quality, output format and background retain their values; aspect ratio and
  resolution are unused. `:provider_options` accepts only `:openai` with
  background, moderation, output_compression and user. Top-level background
  takes nullish precedence. Other optional explicit nil values remain JSON null.

  Config requires explicit `:api_key` and `:base_url`. Optional `:headers` and
  `:request` headers merge in that order before the protocol headers. Other
  transport overrides are unsupported. The base loses trailing slashes and one
  terminal /v1 before /v1 is appended. No saved credentials or defaults resolve.

  Every generation fetches a fresh bounded catalog before one generation POST.
  The first accepted selected row supplies current prompt/count/geometry limits;
  dimensions are validated without normalization. Catalog JSON is capped at
  1 MiB; `:max_image_bytes` has a 64 MiB floor, and generation JSON is capped at
  ceil(image bytes * requested count * 4 / 3) + 1 MiB.

  Call `generate/2` from a supervised execution task. One linked HTTP owner and
  one absolute deadline cover catalog, POST and sequential clean URL downloads
  using shared Req.Finch without retries or polling. PNG/JPEG/WebP signatures
  must agree with MIME. Results contain only selected model and ordered images
  with bytes, MIME, positional filenames and optional revised prompts. Nothing
  registers a catalog/tool, persists media, or activates jobs or delivery.
  """

  @max_image_bytes 64 * 1024 * 1024
  @max_catalog_bytes 1024 * 1024
  @max_timeout 2_147_000_000
  @max_safe_integer 9_007_199_254_740_991
  @chunk_timeout 30_000
  @models ~w(openai/gpt-image-2.5-flare openai/gpt-image-2.5-flare-2026-09-08 openai/gpt-image-2.5-sunburst openai/gpt-image-2.5-sunburst-2026-09-08)
  @limit_keys ~w(maxPromptCharacters maxImages dimensionMultiple minPixels maxPixels maxEdge maxAspectRatio)
  @js_space "[\\x{0009}-\\x{000D}\\x{0020}\\x{00A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}]"
  @js_trim Regex.compile!("\\A#{@js_space}+|#{@js_space}+\\z", "u")
  @transport_keys [
    :auth,
    :proxy,
    :tls,
    :allow_private_network,
    :allowPrivateNetwork,
    :dispatcher_policy,
    :request_options,
    :request_config
  ]

  @spec build_request(map(), map()) :: {:ok, map()} | {:error, term()}
  def build_request(request, config) when is_map(request) and is_map(config) do
    with :ok <- validate_request(request),
         :ok <- validate_config(config),
         {:ok, catalog_headers} <- configured_headers(config) do
      root =
        config.base_url |> trim() |> String.trim_trailing("/") |> String.replace(~r{/v1\z}, "")

      base = root <> "/v1"
      count = if is_nil(request[:count]), do: 1, else: trunc(request.count)
      max_image_bytes = max(@max_image_bytes, Map.get(config, :max_image_bytes, @max_image_bytes))
      options = get_in(request, [:provider_options, :openai])
      options = if is_map(options), do: options, else: %{}
      body = %{"model" => request.model, "prompt" => request.prompt, "n" => count}

      body =
        Enum.reduce(
          [{:size, "size"}, {:quality, "quality"}, {:output_format, "output_format"}],
          body,
          fn {key, wire}, acc ->
            copy_field(acc, request, key, wire)
          end
        )

      body =
        case request[:background] do
          nil -> copy_field(body, options, :background, "background")
          value -> Map.put(body, "background", value)
        end

      body =
        Enum.reduce(
          [
            {:moderation, "moderation"},
            {:output_compression, "output_compression"},
            {:user, "user"}
          ],
          body,
          fn {key, wire}, acc ->
            copy_field(acc, options, key, wire)
          end
        )

      {:ok,
       %{
         catalog_url: base <> "/catalog",
         url: base <> "/images/generations",
         body: body,
         catalog_headers: catalog_headers,
         headers: Map.put(catalog_headers, "content-type", "application/json"),
         model: request.model,
         timeout_ms: request.timeout_ms |> floor() |> max(1) |> min(@max_timeout),
         max_catalog_bytes: @max_catalog_bytes,
         max_image_bytes: max_image_bytes,
         max_downloads: count,
         max_response_bytes: div(max_image_bytes * count * 4 + 2, 3) + @max_catalog_bytes
       }}
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
    options = request[:provider_options] || %{}
    openai = if is_map(options), do: options[:openai]
    count = if is_nil(request[:count]), do: 1, else: request.count

    cond do
      not text?(request[:prompt]) or trim(request.prompt) == "" or
          codepoints(request.prompt) > 32_000 ->
        {:error, :invalid_prompt}

      request[:model] not in @models ->
        {:error, :unsupported_model}

      not (is_number(request[:timeout_ms]) and request.timeout_ms > 0) ->
        {:error, :invalid_timeout}

      not safe_integer?(count) or count < 1 or count > 10 ->
        {:error, :invalid_count}

      request[:input_images] not in [nil, []] ->
        {:error, :unsupported_edit}

      not is_map(options) or Enum.any?(Map.keys(options), &(&1 != :openai)) ->
        {:error, :invalid_options}

      is_map(openai) and
          Enum.any?(
            Map.keys(openai),
            &(&1 not in [:background, :moderation, :output_compression, :user])
          ) ->
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

      not (is_integer(Map.get(config, :max_image_bytes, @max_image_bytes)) and
               Map.get(config, :max_image_bytes, @max_image_bytes) > 0) ->
        {:error, :invalid_max_image_bytes}

      true ->
        :ok
    end
  end

  defp configured_headers(config) do
    request = config[:request] || %{}
    provider_headers = config[:headers] || %{}

    cond do
      Enum.any?(@transport_keys, &nonempty?(config[&1])) ->
        {:error, :unsupported_transport_config}

      not is_map(request) ->
        {:error, :unsupported_transport_config}

      Enum.any?(request, fn {key, value} -> key != :headers and nonempty?(value) end) ->
        {:error, :unsupported_transport_config}

      not header_map?(provider_headers) or not header_map?(request[:headers] || %{}) ->
        {:error, :invalid_headers}

      true ->
        headers =
          Enum.reduce([provider_headers, request[:headers] || %{}], %{}, fn set, headers ->
            Enum.reduce(set, headers, fn {name, value}, acc ->
              case optional_string(value) do
                nil -> acc
                value -> Map.put(acc, name |> trim() |> String.downcase(:ascii), value)
              end
            end)
          end)

        {:ok,
         Map.merge(headers, %{
           "authorization" => "Bearer " <> config.api_key,
           "x-clawrouter-client" => "openclaw",
           "accept" => "application/json"
         })}
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
  defp text?(value), do: is_binary(value) and String.valid?(value)

  defp safe_integer?(value),
    do: is_number(value) and value >= 0 and value <= @max_safe_integer and trunc(value) == value

  defp codepoints(value), do: value |> String.to_charlist() |> length()
  defp trim(value), do: Regex.replace(@js_trim, value, "")

  defp optional_string(value) when is_binary(value) do
    case trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp optional_string(_value), do: nil

  defp copy_field(body, source, key, wire) do
    case Map.fetch(source, key) do
      {:ok, value} -> Map.put(body, wire, value)
      :error -> body
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
  defp remaining(deadline), do: max(0, deadline - now_ms())

  defp check_deadline(deadline),
    do: if(remaining(deadline) > 0, do: :ok, else: {:error, :timeout})

  defp perform(built, deadline) do
    with {:ok, catalog} <-
           http(
             :get,
             built.catalog_url,
             [headers: built.catalog_headers],
             built.max_catalog_bytes,
             deadline
           ),
         {:ok, payload} <- decode_payload(catalog.body),
         {:ok, limits} <- selected_limits(payload, built.model),
         :ok <- assert_limits(built.body, limits),
         {:ok, response} <-
           http(
             :post,
             built.url,
             [headers: built.headers, json: built.body],
             built.max_response_bytes,
             deadline
           ),
         :ok <- check_deadline(deadline),
         {:ok, payload} <- decode_payload(response.body),
         {:ok, entries} <- inline_urls(payload["data"], built, deadline),
         {:ok, images} <- parse_images(entries, built),
         :ok <- check_deadline(deadline) do
      {:ok, %{images: images, model: built.model}}
    end
  rescue
    _exception -> {:error, :transport}
  catch
    :exit, _reason -> {:error, :transport}
  end

  defp selected_limits(
         %{"version" => "clawrouter.client-catalog.v1", "providers" => providers},
         model
       )
       when is_list(providers) do
    providers
    |> Enum.reduce_while(nil, fn provider, _acc ->
      case provider_limits(provider, model) do
        nil -> {:cont, nil}
        limits -> {:halt, limits}
      end
    end)
    |> case do
      nil -> {:error, :model_unavailable}
      limits -> {:ok, limits}
    end
  end

  defp selected_limits(_payload, _model), do: {:error, :malformed_catalog}

  defp provider_limits(
         %{
           "id" => "openai",
           "allowed" => true,
           "executable" => true,
           "models" => models,
           "offers" => offers
         },
         model
       )
       when is_list(models) and is_list(offers) do
    Enum.find_value(models, fn
      %{"id" => id, "capabilities" => capabilities} = row when is_list(capabilities) ->
        if optional_string(id) == model and "image.generation" in capabilities and
             Enum.any?(offers, &eligible_offer?(&1, model)) do
          parse_limits(row["pricing"])
        end

      _ ->
        nil
    end)
  end

  defp provider_limits(_provider, _model), do: nil

  defp eligible_offer?(
         %{
           "endpoint" => "images_generations",
           "modelId" => model,
           "transport" => "http",
           "routeKind" => "unified",
           "route" => "/v1/images/generations",
           "eligible" => true,
           "affordability" => affordability
         },
         model
       ),
       do: affordability in ["exact-covered", "request-dependent"]

  defp eligible_offer?(_offer, _model), do: false

  defp parse_limits(%{"unit" => "image_token", "generation" => limits}) when is_map(limits) do
    if Enum.all?(@limit_keys, &(safe_integer?(limits[&1]) and limits[&1] > 0)) and
         limits["minPixels"] <= limits["maxPixels"] do
      limits
      |> Map.take(@limit_keys)
      |> Map.new(fn {key, value} -> {key, trunc(value)} end)
      |> Map.update!("maxPromptCharacters", &min(32_000, &1))
      |> Map.update!("maxImages", &min(10, &1))
    end
  end

  defp parse_limits(_pricing), do: nil

  defp assert_limits(body, limits) do
    if body["n"] <= limits["maxImages"] and
         codepoints(body["prompt"]) <= limits["maxPromptCharacters"] do
      assert_geometry(body["size"], limits)
    else
      {:error, :catalog_limit}
    end
  end

  defp assert_geometry(size, _limits) when size in [nil, false, "", "auto", 0], do: :ok

  defp assert_geometry(size, limits) when is_binary(size) do
    case Regex.run(~r/\A([0-9]+)x([0-9]+)\z/, size) do
      [_, width, height] ->
        width = String.to_integer(width)
        height = String.to_integer(height)
        pixels = width * height

        if width > 0 and height > 0 and rem(width, limits["dimensionMultiple"]) == 0 and
             rem(height, limits["dimensionMultiple"]) == 0 and pixels >= limits["minPixels"] and
             pixels <= limits["maxPixels"] and max(width, height) <= limits["maxEdge"] and
             max(width, height) <= min(width, height) * limits["maxAspectRatio"] do
          :ok
        else
          {:error, :catalog_geometry}
        end

      _ ->
        {:error, :catalog_geometry}
    end
  end

  defp assert_geometry(_size, _limits), do: {:error, :catalog_geometry}

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
    {size, chunks} = Req.Response.get_private(response, :clawrouter_image_body, {0, []})

    if size + byte_size(data) <= limit do
      {:cont,
       {request,
        Req.Response.put_private(
          response,
          :clawrouter_image_body,
          {size + byte_size(data), [data | chunks]}
        )}}
    else
      {:halt, {request, Req.Response.put_private(response, :clawrouter_image_limit, true)}}
    end
  end

  defp response({:ok, response}) do
    cond do
      Req.Response.get_private(response, :clawrouter_image_limit, false) ->
        {:error, :response_too_large}

      response.status not in 200..299 ->
        {:error, {:http_status, response.status}}

      true ->
        {_size, chunks} = Req.Response.get_private(response, :clawrouter_image_body, {0, []})

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

    case if(String.valid?(body), do: Jason.decode(body), else: {:error, :invalid_utf8}) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      _ -> {:error, :malformed_response}
    end
  end

  defp inline_urls(entries, built, deadline) when is_list(entries) do
    entries
    |> Enum.reduce_while({:ok, [], 0}, fn entry, {:ok, entries, downloads} ->
      with :ok <- check_deadline(deadline),
           {:ok, entry, downloads} <- inline_url(entry, downloads, built, deadline) do
        {:cont, {:ok, [entry | entries], downloads}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries, _downloads} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp inline_urls(_entries, _built, _deadline), do: {:error, :malformed_response}

  defp inline_url(entry, downloads, built, deadline) when is_map(entry) do
    url = if is_nil(optional_string(entry["b64_json"])), do: optional_string(entry["url"])

    if url do
      with true <- downloads < built.max_downloads,
           {:ok, response} <- http(:get, url, [], built.max_image_bytes, deadline),
           mime when is_binary(mime) <- download_mime(response.headers),
           true <- byte_size(response.body) > 0 do
        {:ok,
         Map.merge(entry, %{"b64_json" => Base.encode64(response.body), "mime_type" => mime}),
         downloads + 1}
      else
        {:error, _reason} = error -> error
        _ -> {:error, :malformed_response}
      end
    else
      {:ok, entry, downloads}
    end
  end

  defp inline_url(entry, downloads, _built, _deadline), do: {:ok, entry, downloads}

  defp download_mime(headers) do
    case Map.get(headers, "content-type", []) do
      [value | _] ->
        mime = value |> String.split(";", parts: 2) |> hd() |> trim() |> String.downcase()
        if Regex.match?(~r/\Aimage\/[a-z0-9.+-]+\z/, mime), do: mime

      _ ->
        nil
    end
  end

  defp parse_images(entries, built) when entries != [] do
    if length(entries) <= built.max_downloads do
      entries
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, images} ->
        case parse_image(entry, index, built.max_image_bytes) do
          {:ok, image} -> {:cont, {:ok, [image | images]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, images} -> {:ok, Enum.reverse(images)}
        error -> error
      end
    else
      {:error, :invalid_image_count}
    end
  end

  defp parse_images(_entries, _built), do: {:error, :invalid_image_count}

  defp parse_image(entry, index, limit) when is_map(entry) do
    with base64 when is_binary(base64) <- optional_string(entry["b64_json"]),
         {:ok, bytes} <- decode_image(base64, limit),
         mime when is_binary(mime) <- sniff_mime(bytes),
         true <- (optional_string(entry["mime_type"]) || mime) == mime do
      image = %{data: bytes, mime_type: mime, filename: "image-#{index}." <> extension(mime)}

      case optional_string(entry["revised_prompt"]) do
        nil -> {:ok, image}
        prompt -> {:ok, Map.put(image, :revised_prompt, prompt)}
      end
    else
      {:error, _reason} = error -> error
      _ -> {:error, :malformed_response}
    end
  end

  defp parse_image(_entry, _index, _limit), do: {:error, :malformed_response}

  defp sniff_mime(<<255, 216, 255, _rest::binary>>), do: "image/jpeg"
  defp sniff_mime(<<137, 80, 78, 71, _::binary-size(4), _rest::binary>>), do: "image/png"
  defp sniff_mime(<<"RIFF", _::binary-size(4), "WEBP", _rest::binary>>), do: "image/webp"
  defp sniff_mime(_bytes), do: nil
  defp extension("image/jpeg"), do: "jpg"
  defp extension("image/png"), do: "png"
  defp extension("image/webp"), do: "webp"

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
end
