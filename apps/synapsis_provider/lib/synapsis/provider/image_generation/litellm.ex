defmodule Synapsis.Provider.ImageGeneration.LiteLLM do
  @moduledoc """
  Inactive explicit LiteLLM image generation and editing protocol.

  Atom-keyed requests require `:prompt`, `:model` and positive finite
  `:timeout_ms`. Model identifiers use JavaScript trimming with no prefix
  removal; prompts retain their supplied bytes. Optional positive integer
  `:count` defaults to one without clamping. `:size` defaults to `1024x1024`
  only when absent or nil and otherwise retains its supplied bytes. Aspect
  ratio, resolution, quality, output format, background and provider options
  are source-unused.

  One to five `:input_images` select ordered multipart editing. Each image
  supplies binary `:data` and optional `:mime_type`/`:filename`. MIME and file
  names are trimmed; absent MIME uses image/png and absent names use
  `image-<index>.<mime extension>`. Directory prefixes remain intact. Blob MIME
  uses ASCII lowercase normalization. One image uses `image`; multiple images
  use repeated `image[]`. Editing retains the requested count.

  Config explicitly supplies `:api_key` and `:base_url`. The base URL is trimmed
  and loses trailing slashes without version rewriting. Optional `:request`
  supports only `%{headers: %{string_name => string_value}}`, trimming values
  and merging after the default Bearer header. JSON forces application/json;
  multipart removes configured Content-Type for its generated boundary.
  Nonempty unsupported transport overrides return an error. Environment,
  saved defaults, credentials and the source private-network policy are outside
  this explicit protocol adaptation.

  `:max_image_bytes` defaults to 64 MiB. Raw JSON defaults to
  `ceil(max(64 MiB, max_image_bytes) * 4 * 4 / 3) + 1 MiB` for both operations;
  `:max_response_bytes` can override it. Inline bytes are bounded before decode.
  All ordered response images are retained independently of the requested count.
  Explicit trimmed MIME wins; otherwise image/png is used without sniffing.
  URL downloads use their response Content-Type base and original bytes.

  Call `generate/2` from a supervised execution task. One linked HTTP owner and
  one finite absolute deadline cover POST and at most four sequential image
  downloads using shared Req.Finch, bounded raw bodies and no retries or polling.
  Results contain only images and the selected model. No discovery, saved
  selection, native tool registration, storage, jobs or delivery is activated.
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

  @spec build_request(map(), map()) :: {:ok, map()} | {:error, term()}
  def build_request(request, config) when is_map(request) and is_map(config) do
    with :ok <- validate_request(request),
         :ok <- validate_config(config),
         {:ok, headers} <- configured_headers(config) do
      model = trim(request.model)
      inputs = request[:input_images] || []
      max_image_bytes = Map.get(config, :max_image_bytes, @max_image_bytes)
      max_downloads = 4
      action = if inputs == [], do: "generations", else: "edits"
      count = request[:count] || 1

      fields = [
        {"model", model},
        {"prompt", request.prompt},
        {"n", count},
        {"size", request[:size] || "1024x1024"}
      ]

      built = %{
        url:
          trim(config.base_url) |> String.trim_trailing("/") |> Kernel.<>("/images/" <> action),
        model: model,
        headers: headers,
        timeout_ms: request.timeout_ms,
        max_image_bytes: max_image_bytes,
        max_downloads: max_downloads,
        max_response_bytes:
          Map.get(
            config,
            :max_response_bytes,
            div(max(@max_image_bytes, max_image_bytes) * max_downloads * 4 + 2, 3) + 1024 * 1024
          )
      }

      case inputs do
        [] ->
          {:ok,
           built
           |> Map.put(:body, Map.new(fields))
           |> Map.update!(:headers, &Map.put(&1, "content-type", "application/json"))}

        images ->
          form = Enum.map(fields, fn {name, value} -> {name, to_string(value)} end)
          part_name = if length(images) > 1, do: "image[]", else: "image"

          uploads =
            images
            |> Enum.with_index(1)
            |> Enum.map(fn {image, index} -> upload_part(image, index, part_name) end)

          {:ok,
           built
           |> Map.put(:form, form ++ uploads)
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

      not is_nil(request[:count]) and not positive_integer?(request.count) ->
        {:error, :invalid_count}

      not optional_text?(request[:size]) ->
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

  defp input_image?(image) when is_map(image) do
    is_binary(image[:data]) and optional_text?(image[:mime_type]) and
      optional_text?(image[:filename])
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

  defp upload_part(image, index, part_name) do
    mime = optional_string(image[:mime_type]) || "image/png"
    filename = optional_string(image[:filename]) || "image-#{index}." <> extension(mime)

    blob_mime =
      if mime |> :binary.bin_to_list() |> Enum.all?(&(&1 in 0x20..0x7E)),
        do: String.downcase(mime, :ascii),
        else: ""

    wire_mime = if blob_mime == "", do: "application/octet-stream", else: blob_mime
    {part_name, {image.data, filename: filename, content_type: wire_mime}}
  end

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
    {size, chunks} = Req.Response.get_private(response, :litellm_image_body, {0, []})

    if size + byte_size(data) <= limit do
      {:cont,
       {request,
        Req.Response.put_private(
          response,
          :litellm_image_body,
          {size + byte_size(data), [data | chunks]}
        )}}
    else
      {:halt, {request, Req.Response.put_private(response, :litellm_image_limit, true)}}
    end
  end

  defp response({:ok, response}) do
    cond do
      Req.Response.get_private(response, :litellm_image_limit, false) ->
        {:error, :response_too_large}

      response.status not in 200..299 ->
        {:error, {:http_status, response.status}}

      true ->
        {_size, chunks} = Req.Response.get_private(response, :litellm_image_body, {0, []})

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
             true <- downloads < built.max_downloads,
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
