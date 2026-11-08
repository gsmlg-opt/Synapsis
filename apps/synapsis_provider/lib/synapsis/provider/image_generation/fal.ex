defmodule Synapsis.Provider.ImageGeneration.Fal do
  @moduledoc """
  Inactive, explicit FAL image-generation callback protocol.

  Requests supply `:prompt`, `:model` and a positive finite `:timeout_ms`.
  Model whitespace is trimmed; prefixes and prompt bytes are retained. The
  pinned callback's GPT 2.5, Krea, Nano Banana, GPT, Lite, Grok and fallback
  schemas select geometry, reference fields and automatic edit paths. Ordered
  `:input_images` use exact binary `:data` and trimmed `:mime_type` (PNG by
  default); filenames are unused. Positive integer counts are sent unchanged,
  except Krea only accepts one and omits count and output format.

  Config explicitly supplies `:api_key` and `:base_url`. Optional `:request`
  supports only a string-map `:headers`, merged after the default Key and JSON
  headers. Other transport overrides are unsupported. This host boundary does
  not resolve saved credentials, environment configuration or transport policy.
  JSON is bounded to 16 MiB by default, optionally `:max_response_bytes`.
  Per-image downloads use at least 64 MiB, or a larger `:max_image_bytes`.

  Call `generate/2` from a supervised task. One linked HTTP owner and one
  absolute deadline cover preflight, POST, parsing and every sequential GET
  through shared Req.Finch, with bounded bodies, no retries and no polling.
  Downloads receive no configured POST headers. Every ordered URL result is
  retained with exact bytes, full trimmed Content-Type (PNG by default) and a
  stable image-N filename. Optional returned prompt metadata is trimmed.

  This module performs no runtime geometry normalization, model registration,
  discovery, jobs, storage, custody, tool activation or delivery.
  """

  @max_image_bytes 64 * 1024 * 1024
  @max_response_bytes 16 * 1024 * 1024
  @max_timeout 2_147_000_000
  @chunk_timeout 30_000
  @gpt25 ~w(openai/gpt-image-2.5/flare/text-to-image openai/gpt-image-2.5/flare/edit openai/gpt-image-2.5/sunburst/text-to-image openai/gpt-image-2.5/sunburst/edit)
  @krea_ratios ~w(1:1 4:3 3:2 16:9 2.35:1 4:5 2:3 9:16)
  @nano_ratios ~w(21:9 16:9 3:2 4:3 5:4 1:1 4:5 3:4 2:3 9:16)
  @nano2_ratios @nano_ratios ++ ~w(4:1 1:4 8:1 1:8)
  @grok_ratios ~w(2:1 20:9 19.5:9 16:9 4:3 3:2 1:1 2:3 3:4 9:16 9:19.5 9:20 1:2)
  @named_sizes %{
    "1:1" => "square_hd",
    "4:3" => "landscape_4_3",
    "3:4" => "portrait_4_3",
    "16:9" => "landscape_16_9",
    "9:16" => "portrait_16_9"
  }
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

  @spec build_request(map(), map()) :: {:ok, map()} | {:error, term()}
  def build_request(request, config) when is_map(request) and is_map(config) do
    with :ok <- validate_request(request),
         :ok <- validate_config(config),
         {:ok, headers} <- configured_headers(config),
         model = trim(request.model),
         schema = schema(model),
         inputs = request[:input_images] || [],
         :ok <- validate_schema(request, schema, inputs),
         {:ok, image_size} <- image_size(request, schema, inputs != []),
         {:ok, body} <- request_body(request, schema, image_size, inputs) do
      model = model_path(model, schema, inputs != [])

      {:ok,
       %{
         url: trim(config.base_url) |> String.trim_trailing("/") |> Kernel.<>("/" <> model),
         body: body,
         model: model,
         headers: headers,
         timeout_ms: request.timeout_ms |> floor() |> max(1) |> min(@max_timeout),
         max_image_bytes:
           max(@max_image_bytes, Map.get(config, :max_image_bytes, @max_image_bytes)),
         max_response_bytes: Map.get(config, :max_response_bytes, @max_response_bytes)
       }}
    end
  end

  def build_request(_request, _config), do: {:error, :invalid_request}

  @spec generate(map(), map()) :: {:ok, map()} | {:error, term()}
  def generate(request, config) do
    started = now_ms()

    with {:ok, built} <- build_request(request, config) do
      deadline = started + built.timeout_ms
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

      not (is_number(request[:timeout_ms]) and request.timeout_ms > 0) ->
        {:error, :invalid_timeout}

      not is_nil(request[:count]) and not positive_integer?(request.count) ->
        {:error, :invalid_count}

      not Enum.all?(
        [:size, :aspect_ratio, :resolution, :quality, :output_format, :background],
        &optional_text?(request[&1])
      ) ->
        {:error, :invalid_request}

      not is_list(inputs) or not Enum.all?(inputs, &input_image?/1) ->
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

      not positive_integer?(Map.get(config, :max_response_bytes, @max_response_bytes)) ->
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

  defp header_map?(headers) when is_map(headers) do
    Enum.all?(headers, fn {name, value} ->
      text?(name) and Regex.match?(~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/, trim(name)) and
        text?(value) and not String.contains?(value, ["\r", "\n", <<0>>])
    end)
  end

  defp header_map?(_headers), do: false

  defp schema(model) do
    cond do
      model in @gpt25 ->
        %{kind: :gpt25, max_inputs: 16, ratios: nil}

      String.starts_with?(model, "krea/v2/") ->
        %{kind: :krea, max_inputs: 10, ratios: @krea_ratios}

      model == "fal-ai/nano-banana" or String.starts_with?(model, "fal-ai/nano-banana/") ->
        %{kind: :legacy, max_inputs: 3, ratios: @nano_ratios}

      String.starts_with?(model, "openai/gpt-image-") ->
        %{kind: :gpt, max_inputs: 10, ratios: nil}

      String.starts_with?(model, "fal-ai/nano-banana-") ->
        %{kind: :nano, max_inputs: 14, ratios: @nano2_ratios}

      String.starts_with?(model, "google/nano-banana-2-lite") ->
        %{kind: :lite, max_inputs: 14, ratios: @nano2_ratios}

      String.starts_with?(model, "xai/grok-imagine-image") ->
        %{kind: :grok, max_inputs: 3, ratios: @grok_ratios}

      true ->
        %{kind: :fallback, max_inputs: 1, ratios: nil}
    end
  end

  defp validate_schema(request, schema, inputs) do
    cond do
      length(inputs) > schema.max_inputs ->
        {:error, :invalid_input_images}

      schema.kind == :gpt25 and truthy?(request[:resolution]) ->
        {:error, :unsupported_resolution}

      schema.kind == :fallback and inputs != [] and truthy?(request[:aspect_ratio]) ->
        {:error, :unsupported_aspect_ratio}

      schema.kind == :krea and (request[:count] || 1) > 1 ->
        {:error, :invalid_count}

      schema.kind == :krea and truthy?(request[:output_format]) ->
        {:error, :unsupported_output_format}

      schema.kind in [:krea, :legacy, :lite] and truthy?(request[:resolution]) ->
        {:error, :unsupported_resolution}

      schema.kind == :grok and truthy?(request[:resolution]) and
          request.resolution not in ["1K", "2K"] ->
        {:error, :unsupported_resolution}

      true ->
        :ok
    end
  end

  defp model_path(model, _schema, false), do: model
  defp model_path(model, %{kind: :krea}, true), do: model

  defp model_path(model, %{kind: :gpt25}, true),
    do: String.replace_suffix(model, "/text-to-image", "/edit")

  defp model_path(model, schema, true) do
    suffix = if schema.kind == :fallback, do: "image-to-image", else: "edit"

    if String.contains?(model, "/image-to-image/") or
         Enum.any?([suffix, "edit", "image-to-image"], &String.ends_with?(model, "/" <> &1)),
       do: model,
       else: model <> "/" <> suffix
  end

  defp image_size(request, schema, has_inputs) do
    cond do
      schema.kind == :gpt25 and request[:size] == "auto" ->
        {:ok, "auto"}

      schema.kind == :gpt25 and truthy?(request[:size]) and is_nil(parse_size(request[:size])) ->
        {:error, :invalid_size}

      schema.kind == :gpt25 and truthy?(request[:aspect_ratio]) and not truthy?(request[:size]) ->
        with {:ok, size} <- ratio_dimensions(request.aspect_ratio, 1536) do
          size = Map.new(size, fn {key, value} -> {key, round(value / 16) * 16} end)
          validate_gpt_size(size)
        end

      true ->
        with {:ok, size} <- general_image_size(request, has_inputs) do
          if schema.kind == :gpt25, do: validate_gpt_size(size), else: {:ok, size}
        end
    end
  end

  defp general_image_size(request, has_inputs) do
    parsed = parse_size(request[:size])
    ratio = optional_string(request[:aspect_ratio])
    edge = if truthy?(request[:resolution]), do: resolution_edge(request.resolution)

    cond do
      parsed -> {:ok, parsed}
      ratio && edge && not has_inputs -> ratio_dimensions(ratio, edge)
      ratio && Map.has_key?(@named_sizes, ratio) -> {:ok, @named_sizes[ratio]}
      ratio -> ratio_dimensions(ratio, 1024)
      edge -> {:ok, %{"width" => edge, "height" => edge}}
      true -> {:ok, nil}
    end
  end

  defp parse_size(value) when is_binary(value) do
    case Regex.run(~r/\A(\d{2,5})x(\d{2,5})\z/iu, trim(value)) do
      [_, width, height] ->
        width = String.to_integer(width)
        height = String.to_integer(height)
        if width > 0 and height > 0, do: %{"width" => width, "height" => height}

      _ ->
        nil
    end
  end

  defp parse_size(_value), do: nil
  defp resolution_edge("4K"), do: 4096
  defp resolution_edge("2K"), do: 2048
  defp resolution_edge(_resolution), do: 1024

  defp ratio_parts(value) do
    case Regex.run(~r/\A(\d+(?:\.\d+)?):(\d+(?:\.\d+)?)\z/u, trim(value)) do
      [_, width, height] ->
        {width, ""} = Float.parse(width)
        {height, ""} = Float.parse(height)

        if width > 0 and height > 0,
          do: {:ok, width, height},
          else: {:error, :invalid_aspect_ratio}

      _ ->
        {:error, :invalid_aspect_ratio}
    end
  end

  defp ratio_dimensions(ratio, edge) do
    with {:ok, width, height} <- ratio_parts(ratio) do
      if width >= height,
        do: {:ok, %{"width" => edge, "height" => max(1, round(edge * height / width))}},
        else: {:ok, %{"width" => max(1, round(edge * width / height)), "height" => edge}}
    end
  end

  defp validate_gpt_size(nil), do: {:ok, nil}
  defp validate_gpt_size(size) when is_binary(size), do: {:ok, size}

  defp validate_gpt_size(%{"width" => width, "height" => height} = size) do
    if rem(width, 16) == 0 and rem(height, 16) == 0 and max(width, height) <= 3840 and
         (width * height) in 655_360..8_294_400 and width <= height * 3 and height <= width * 3,
       do: {:ok, size},
       else: {:error, :invalid_size}
  end

  defp request_body(request, schema, image_size, inputs) do
    body = %{"prompt" => request.prompt}

    body =
      if schema.kind == :krea do
        Map.put(body, "creativity", creativity(request[:provider_options]))
      else
        body
        |> Map.put("num_images", request[:count] || 1)
        |> Map.put("output_format", request[:output_format] || "png")
      end

    body =
      if schema.kind == :gpt25 do
        Enum.reduce([:quality, :background], body, fn key, acc ->
          if truthy?(request[key]), do: Map.put(acc, Atom.to_string(key), request[key]), else: acc
        end)
      else
        body
      end

    with {:ok, body} <- body_geometry(body, request, schema, image_size) do
      encoded = Enum.map(inputs, &image_data_url/1)

      body =
        case {schema.kind, encoded} do
          {_, []} ->
            body

          {:krea, images} ->
            Map.put(body, "image_style_references", Enum.map(images, &%{"image_url" => &1}))

          {:fallback, [image]} ->
            Map.put(body, "image_url", image)

          {_, images} ->
            Map.put(body, "image_urls", images)
        end

      {:ok, body}
    end
  end

  defp body_geometry(body, request, %{ratios: nil}, image_size) do
    _ = request
    {:ok, if(is_nil(image_size), do: body, else: Map.put(body, "image_size", image_size))}
  end

  defp body_geometry(body, request, schema, image_size) do
    ratio = optional_string(request[:aspect_ratio])

    cond do
      ratio && ratio not in schema.ratios ->
        {:error, :unsupported_aspect_ratio}

      true ->
        ratio = ratio || nearest_ratio(request, schema.ratios, image_size)
        body = if ratio, do: Map.put(body, "aspect_ratio", ratio), else: body
        resolution = request[:resolution]

        resolution =
          if schema.kind == :grok and truthy?(resolution),
            do: String.downcase(resolution),
            else: resolution

        body = if truthy?(resolution), do: Map.put(body, "resolution", resolution), else: body
        {:ok, body}
    end
  end

  defp nearest_ratio(request, ratios, %{"width" => width, "height" => height}) do
    if truthy?(request[:size]) do
      target = :math.log(width / height)

      Enum.reduce(ratios, nil, fn candidate, best ->
        if is_nil(best) or ratio_score(candidate, target) < ratio_score(best, target),
          do: candidate,
          else: best
      end)
    end
  end

  defp nearest_ratio(_request, _ratios, _image_size), do: nil

  defp ratio_score(ratio, target) do
    {:ok, width, height} = ratio_parts(ratio)
    abs(:math.log(width / height) - target)
  end

  defp creativity(options) do
    fal = if is_map(options), do: options[:fal] || options["fal"]
    value = if is_map(fal), do: fal[:creativity] || fal["creativity"]
    value = if is_binary(value), do: value |> trim() |> String.downcase(), else: nil
    if value in ~w(raw low medium high), do: value, else: "medium"
  end

  defp image_data_url(image),
    do:
      "data:" <>
        (optional_string(image[:mime_type]) || "image/png") <>
        ";base64," <> Base.encode64(image.data)

  defp input_image?(image) when is_map(image),
    do: is_binary(image[:data]) and optional_text?(image[:mime_type])

  defp input_image?(_image), do: false
  defp text?(value), do: is_binary(value) and String.valid?(value)
  defp optional_text?(nil), do: true
  defp optional_text?(value), do: text?(value)
  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp nonempty?(value), do: value not in [nil, "", [], %{}]
  defp truthy?(value), do: value not in [nil, false, ""]
  defp trim(value), do: Regex.replace(@js_trim, value, "")

  defp optional_string(value) when is_binary(value) do
    case trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp optional_string(_value), do: nil
  defp now_ms, do: System.monotonic_time(:millisecond)
  defp remaining(deadline), do: max(0, deadline - now_ms())

  defp check_deadline(deadline),
    do: if(remaining(deadline) > 0, do: :ok, else: {:error, :timeout})

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
         {:ok, images} <- read_images(payload["images"], built, deadline),
         :ok <- check_deadline(deadline) do
      result = %{images: images, model: built.model}
      prompt = optional_string(payload["prompt"])
      {:ok, if(prompt, do: Map.put(result, :metadata, %{prompt: prompt}), else: result)}
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
            receive_timeout: if(method == :post, do: min(timeout, @chunk_timeout), else: timeout),
            request_timeout: timeout,
            finch: [pool_timeout: timeout]
          ]
      )
      |> Req.request()
      |> response()
    end
  end

  defp collect({:data, data}, {request, response}, limit) do
    {size, chunks} = Req.Response.get_private(response, :fal_image_body, {0, []})

    if size + byte_size(data) <= limit do
      {:cont,
       {request,
        Req.Response.put_private(
          response,
          :fal_image_body,
          {size + byte_size(data), [data | chunks]}
        )}}
    else
      {:halt, {request, Req.Response.put_private(response, :fal_image_limit, true)}}
    end
  end

  defp response({:ok, response}) do
    cond do
      Req.Response.get_private(response, :fal_image_limit, false) ->
        {:error, :response_too_large}

      response.status not in 200..299 ->
        {:error, {:http_status, response.status}}

      true ->
        {_size, chunks} = Req.Response.get_private(response, :fal_image_body, {0, []})

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

    with true <- String.valid?(body),
         {:ok, payload} when is_map(payload) <- Jason.decode(body),
         images = if(is_nil(payload["images"]), do: [], else: payload["images"]),
         true <- is_list(images) and Enum.all?(images, &is_map/1) do
      {:ok, Map.put(payload, "images", images)}
    else
      _ -> {:error, :malformed_response}
    end
  end

  defp read_images(entries, built, deadline) when is_list(entries) and entries != [] do
    entries
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, images} ->
      with :ok <- check_deadline(deadline),
           {:ok, image} <- read_image(entry, index, built, deadline) do
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

  defp read_image(entry, index, built, deadline) when is_map(entry) do
    with url when is_binary(url) <- optional_string(entry["url"]),
         {:ok, response} <- http(:get, url, [], built.max_image_bytes, deadline) do
      mime = response.headers |> Map.get("content-type", []) |> List.first() |> optional_string()
      mime = mime || "image/png"

      {:ok,
       %{data: response.body, mime_type: mime, filename: "image-#{index}." <> extension(mime)}}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :malformed_response}
    end
  end

  defp read_image(_entry, _index, _built, _deadline), do: {:error, :malformed_response}

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
