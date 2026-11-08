defmodule Synapsis.Provider.ImageGeneration.OpenRouter do
  @moduledoc """
  Inactive explicit OpenRouter image protocol, pinned to OpenClaw 488631c.

  Requests require atom-keyed `:prompt`, `:model` and finite positive integer
  `:timeout_ms`; config requires `:api_key` and `:base_url`. Model uses JavaScript
  trim without removing a prefix. Count defaults to one, floors and clamps 1..4.
  Exact canonical/legacy official roots use concurrent single-image `/images`
  requests. Custom roots use one `/chat/completions` request with the full count.
  Only `google/gemini-` models receive trimmed aspect ratio/resolution fields.
  Up to five typed reference images retain their bytes and trimmed MIME (PNG
  default). Filenames, size, quality, background and provider options are unused.

  Optional `:request` supports only a string header map. Headers merge after
  Bearer authentication. The plan retains source headers; actual string-body
  HTTP adds native fetch's `text/plain;charset=UTF-8` only when Content-Type is
  absent. Other nonempty transport policy overrides return unsupported. This
  explicit adaptation does not resolve saved credentials or source network policy.

  `:max_image_bytes` defaults to 64 MiB and bounds decoding before allocation.
  JSON response budgets use the source media floor and one payload per dedicated
  request or twice the requested count for chat; `:max_response_bytes` overrides
  that bound. Every returned inline image is retained in source order. Dedicated
  responses sniff JPEG/PNG/WebP only without explicit MIME and retain revised
  prompts. Chat parses data URLs and inline base64 without downloads or sniffing.

  Call from a supervised execution task. One linked HTTP owner starts at most
  four linked request tasks using shared Req.Finch and one absolute deadline
  covering HTTP and decoding. All children are cleaned up before owner exit.
  No retries, polling, activation, registration, storage or delivery occurs.
  """

  @max_image_bytes 64 * 1024 * 1024
  @max_timeout 2_147_483_647
  @chunk_timeout 30_000
  @official "https://openrouter.ai/api/v1"
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
         {:ok, headers} <- configured_headers(config) do
      base = config.base_url |> trim() |> String.trim_trailing("/")
      dedicated = base in [@official, "https://openrouter.ai/v1"]
      count = count(request[:count])
      model = trim(request.model)
      references = Enum.map(request[:input_images] || [], &reference/1)
      max_image_bytes = Map.get(config, :max_image_bytes, @max_image_bytes)
      payload_count = if dedicated, do: 1, else: count * 2

      {:ok,
       %{
         url: if(dedicated, do: @official <> "/images", else: base <> "/chat/completions"),
         model: model,
         mode: if(dedicated, do: :dedicated, else: :chat),
         request_count: if(dedicated, do: count, else: 1),
         headers: headers,
         body: body(request, model, references, count, dedicated),
         timeout_ms: request.timeout_ms,
         max_image_bytes: max_image_bytes,
         max_response_bytes:
           Map.get(
             config,
             :max_response_bytes,
             div(max(@max_image_bytes, max_image_bytes) * payload_count * 4 + 2, 3) + 1024 * 1024
           )
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

  defp body(request, model, references, _count, true) do
    %{"model" => model, "prompt" => request.prompt, "n" => 1}
    |> geometry(request, model, true)
    |> then(fn body ->
      if references == [], do: body, else: Map.put(body, "input_references", references)
    end)
  end

  defp body(request, model, references, count, false) do
    content =
      if references == [],
        do: request.prompt,
        else: [%{"type" => "text", "text" => request.prompt} | references]

    %{
      "model" => model,
      "messages" => [%{"role" => "user", "content" => content}],
      "modalities" => ["image", "text"],
      "n" => count
    }
    |> geometry(request, model, false)
  end

  defp geometry(body, request, model, dedicated) do
    if String.starts_with?(model, "google/gemini-") do
      fields = %{}

      fields =
        if aspect = optional_string(request[:aspect_ratio]),
          do: Map.put(fields, "aspect_ratio", aspect),
          else: fields

      resolution_key = if dedicated, do: "resolution", else: "image_size"

      fields =
        if resolution = optional_string(request[:resolution]),
          do: Map.put(fields, resolution_key, resolution),
          else: fields

      cond do
        dedicated -> Map.merge(body, fields)
        fields == %{} -> body
        true -> Map.put(body, "image_config", fields)
      end
    else
      body
    end
  end

  defp reference(image) do
    mime = optional_string(image[:mime_type]) || "image/png"

    %{
      "type" => "image_url",
      "image_url" => %{"url" => "data:#{mime};base64," <> Base.encode64(image.data)}
    }
  end

  defp count(value) when is_number(value), do: value |> floor() |> max(1) |> min(4)
  defp count(_value), do: 1

  defp validate_request(request) do
    inputs = request[:input_images] || []

    cond do
      not text?(request[:prompt]) or not text?(request[:model]) ->
        {:error, :invalid_request}

      trim(request.model) == "" ->
        {:error, :invalid_request}

      not (positive_integer?(request[:timeout_ms]) and request.timeout_ms <= @max_timeout) ->
        {:error, :invalid_timeout}

      not Enum.all?([:aspect_ratio, :resolution], &optional_text?(request[&1])) ->
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

  defp header_map?(headers) when is_map(headers) do
    Enum.all?(headers, fn {name, value} ->
      text?(name) and Regex.match?(~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/, trim(name)) and
        text?(value) and not String.contains?(value, ["\r", "\n", <<0>>])
    end)
  end

  defp header_map?(_headers), do: false
  defp nonempty?(value), do: value not in [nil, "", [], %{}]

  defp input_image?(image) when is_map(image),
    do: is_binary(image[:data]) and optional_text?(image[:mime_type])

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
  defp now_ms, do: System.monotonic_time(:millisecond)
  defp remaining(deadline), do: max(0, deadline - now_ms())

  defp check_deadline(deadline),
    do: if(remaining(deadline) > 0, do: :ok, else: {:error, :timeout})

  defp perform(built, deadline) do
    tasks =
      for index <- 0..(built.request_count - 1),
          do: Task.async(fn -> perform_one(built, index, deadline) end)

    try do
      tasks
      |> Enum.reduce_while({:ok, []}, fn task, {:ok, batches} ->
        case Task.yield(task, remaining(deadline)) do
          {:ok, {:ok, images}} -> {:cont, {:ok, [images | batches]}}
          {:ok, {:error, _reason} = error} -> {:halt, error}
          {:exit, _reason} -> {:halt, {:error, :transport}}
          nil -> {:halt, {:error, :timeout}}
        end
      end)
      |> case do
        {:ok, batches} ->
          with :ok <- check_deadline(deadline),
               do:
                 {:ok, %{images: batches |> Enum.reverse() |> List.flatten(), model: built.model}}

        error ->
          error
      end
    after
      Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
    end
  end

  defp perform_one(built, index, deadline) do
    with :ok <- check_deadline(deadline),
         {:ok, body} <- http(built, index, deadline),
         :ok <- check_deadline(deadline),
         {:ok, payload} <- decode_payload(body),
         {:ok, images} <- read_images(payload, built, deadline),
         :ok <- check_deadline(deadline) do
      {:ok, images}
    end
  rescue
    _exception -> {:error, :transport}
  catch
    :exit, _reason -> {:error, :transport}
  end

  defp http(built, index, deadline) do
    timeout = remaining(deadline)
    headers = Map.put_new(built.headers, "content-type", "text/plain;charset=UTF-8")

    Req.new(
      method: :post,
      url: built.url,
      headers: headers,
      body: Jason.encode!(built.body),
      raw: true,
      compressed: false,
      into: fn event, pair -> collect(event, pair, built.max_response_bytes) end,
      retry: false,
      redirect: false,
      receive_timeout: min(timeout, @chunk_timeout),
      request_timeout: timeout,
      finch: [pool_timeout: timeout]
    )
    |> Req.Request.put_private(:openrouter_image_request_index, index)
    |> Req.request()
    |> response()
  end

  defp collect({:data, data}, {request, response}, limit) do
    {size, chunks} = Req.Response.get_private(response, :openrouter_image_body, {0, []})

    if size + byte_size(data) <= limit do
      {:cont,
       {request,
        Req.Response.put_private(
          response,
          :openrouter_image_body,
          {size + byte_size(data), [data | chunks]}
        )}}
    else
      {:halt, {request, Req.Response.put_private(response, :openrouter_image_limit, true)}}
    end
  end

  defp response({:ok, response}) do
    cond do
      Req.Response.get_private(response, :openrouter_image_limit, false) ->
        {:error, :response_too_large}

      response.status not in 200..299 ->
        {:error, {:http_status, response.status}}

      true ->
        {_size, chunks} = Req.Response.get_private(response, :openrouter_image_body, {0, []})
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
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

  defp read_images(payload, %{mode: :dedicated} = built, deadline) do
    with {:ok, entries} <- list(payload["data"]) do
      entries
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, images} ->
        with :ok <- check_deadline(deadline),
             true <- is_map(entry),
             base64 when is_binary(base64) <- optional_string(entry["b64_json"]),
             {:ok, bytes} <- decode_image(base64, built.max_image_bytes) do
          raw_mime =
            if Map.has_key?(entry, "mime_type"), do: entry["mime_type"], else: entry["media_type"]

          mime = optional_string(raw_mime) || sniff_mime(bytes)
          image = asset(bytes, mime, index)

          image =
            if prompt = optional_string(entry["revised_prompt"]),
              do: Map.put(image, :revised_prompt, prompt),
              else: image

          {:cont, {:ok, [image | images]}}
        else
          {:error, _reason} = error -> {:halt, error}
          _ -> {:halt, {:error, :malformed_response}}
        end
      end)
      |> finish_images()
    end
  end

  defp read_images(payload, built, deadline) do
    with {:ok, choices} <- list(payload["choices"]) do
      Enum.reduce_while(choices, {:ok, []}, fn choice, {:ok, images} ->
        with :ok <- check_deadline(deadline),
             {:ok, images} <- read_choice(choice, images, built.max_image_bytes, deadline) do
          {:cont, {:ok, images}}
        else
          error -> {:halt, error}
        end
      end)
      |> finish_images()
    end
  end

  defp finish_images({:ok, []}), do: {:error, :missing_image_data}
  defp finish_images({:ok, images}), do: {:ok, Enum.reverse(images)}
  defp finish_images(error), do: error
  defp list(nil), do: {:ok, []}
  defp list(value) when is_list(value), do: {:ok, value}
  defp list(_value), do: {:error, :malformed_response}

  defp read_choice(choice, images, limit, deadline) when is_map(choice) do
    case choice["message"] do
      nil ->
        {:ok, images}

      message when is_map(message) ->
        with {:ok, entries} <- list(message["images"]),
             {:ok, images} <- read_entries(entries, images, limit, deadline),
             {:ok, images} <- read_content(message["content"], images, limit, deadline) do
          {:ok, images}
        end

      _ ->
        {:error, :malformed_response}
    end
  end

  defp read_choice(_choice, _images, _limit, _deadline), do: {:error, :malformed_response}

  defp read_entries(entries, images, limit, deadline) do
    Enum.reduce_while(entries, {:ok, images}, fn entry, {:ok, images} ->
      with :ok <- check_deadline(deadline),
           {:ok, url} <- image_url(entry),
           {:ok, image} <- data_url_asset(url, length(images), limit) do
        {:cont, {:ok, [image | images]}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp read_content(nil, images, _limit, _deadline), do: {:ok, images}

  defp read_content(content, images, limit, deadline) when is_binary(content) do
    Regex.scan(~r/data:image\/[^;]+;base64,[A-Za-z0-9+\/=]+/, content)
    |> Enum.reduce_while({:ok, images}, fn [url], {:ok, images} ->
      with :ok <- check_deadline(deadline) do
        case data_url_asset(url, length(images), limit) do
          {:ok, image} -> {:cont, {:ok, [image | images]}}
          {:error, :malformed_response} -> {:cont, {:ok, images}}
          error -> {:halt, error}
        end
      else
        error -> {:halt, error}
      end
    end)
  end

  defp read_content(parts, images, limit, deadline) when is_list(parts) do
    Enum.reduce_while(parts, {:ok, images}, fn part, {:ok, images} ->
      with :ok <- check_deadline(deadline),
           {:ok, image} <- part_asset(part, length(images), limit) do
        {:cont, {:ok, if(is_nil(image), do: images, else: [image | images])}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp read_content(_content, _images, _limit, _deadline), do: {:error, :malformed_response}

  defp image_url(entry) when is_map(entry) do
    value = nullish(entry["image_url"], entry["imageUrl"])

    with true <- is_map(value), url when is_binary(url) <- optional_string(value["url"]) do
      {:ok, url}
    else
      _ -> {:error, :malformed_response}
    end
  end

  defp image_url(_entry), do: {:error, :malformed_response}

  defp part_asset(%{"type" => "text"}, _index, _limit), do: {:ok, nil}

  defp part_asset(%{"type" => "image_url"} = part, index, limit) do
    with {:ok, url} <- image_url(part), do: data_url_asset(url, index, limit)
  end

  defp part_asset(part, index, limit) when is_map(part) do
    cond do
      base64 = optional_string(part["b64_json"]) ->
        base64_asset(base64, "image/png", index, limit)

      Map.has_key?(part, "b64_json") ->
        {:error, :malformed_response}

      true ->
        case nullish(part["inlineData"], part["inline_data"]) do
          nil ->
            {:ok, nil}

          inline when is_map(inline) ->
            mime =
              optional_string(inline["mimeType"]) || optional_string(inline["mime_type"]) ||
                "image/png"

            case optional_string(inline["data"]) do
              nil -> {:error, :malformed_response}
              data -> base64_asset(data, mime, index, limit)
            end

          _ ->
            {:error, :malformed_response}
        end
    end
  end

  defp part_asset(_part, _index, _limit), do: {:error, :malformed_response}

  defp nullish(nil, fallback), do: fallback
  defp nullish(value, _fallback), do: value

  defp data_url_asset(url, index, limit) do
    case Regex.run(~r/\Adata:(image\/[^;,]+)(?:;[^,]*)?;base64,(.+)\z/is, url) do
      [_, mime, base64] -> base64_asset(base64, trim(mime), index, limit)
      _ -> {:error, :malformed_response}
    end
  end

  defp base64_asset(base64, mime, index, limit) do
    with {:ok, bytes} <- decode_image(base64, limit), do: {:ok, asset(bytes, mime, index)}
  end

  defp decode_image(data, limit) do
    cleaned = data |> trim() |> then(&Regex.replace(~r/[\x00-\x20]/, &1, ""))
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

  defp asset(bytes, mime, index),
    do: %{data: bytes, mime_type: mime, filename: "image-#{index + 1}." <> extension(mime)}

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
