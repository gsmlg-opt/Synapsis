defmodule Synapsis.Provider.ImageGeneration.MiniMax do
  @moduledoc """
  Inactive explicit MiniMax image generation protocol (OpenClaw 488631c).

  Atom-keyed requests require explicit `:prompt`, a nonempty raw `:model` and
  positive finite integer `:timeout_ms`. Models and prompts retain their bytes;
  models are neither trimmed nor stripped of a provider prefix. Optional positive
  integer `:count` defaults to one when absent or nil, without clamping. Only a
  nonblank JavaScript-trimmed `:aspect_ratio` adds geometry. Size, resolution,
  quality, output format, background and provider options are source-unused.

  Ordered `:input_images` contain binary `:data` and optional raw `:mime_type`.
  Only the first entry becomes a character subject reference data URL. A missing
  or empty MIME defaults to image/jpeg; whitespace, case and parameters remain
  intact. Filenames are ignored. The source advertises maxInputImages=1 in its
  capability metadata but its direct callback accepts a list and uses at(0);
  this protocol preserves that direct callback behavior.

  Config supplies explicit `:api_key`, an effective image `:base_url` and optional
  `:provider_id` (minimax by default, or minimax-portal). The base is trimmed and
  loses trailing slashes before /v1/image_generation is appended. No model,
  environment, region, saved credential or saved provider resolution is performed.
  Optional `:request` accepts only `%{headers: %{string_name => string_value}}`;
  values are trimmed, merged after Bearer authorization and JSON content type is
  forced. Nonempty unsupported transport settings return an error. This explicit
  adaptation does not reproduce the source's configured transport policy.

  `:max_image_bytes` defaults to 64 MiB. The raw response default is
  `ceil(max(64 MiB, max_image_bytes) * 9 * 4 / 3) + 1 MiB`; an explicit positive
  `:max_response_bytes` overrides it. A host predecode per-image byte bound applies.
  Canonical padded/unpadded Base64 and ASCII whitespace are supported. Empty
  strings are skipped, preserving original response indices in PNG filenames.
  Every returned image uses image/png regardless of its bytes. Results contain
  only `:images` (data, mime_type, filename) and the original `:model`.

  Call `generate/2` from a supervised execution task. One linked HTTP owner uses
  shared Req.Finch, one finite absolute deadline and bounded raw JSON reads, with
  finite pool/request waits and chunk idle waits at most 30 seconds. There are no
  retries, polling, downloads, registration, jobs, storage or delivery activation.
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
      max_image_bytes = Map.get(config, :max_image_bytes, @max_image_bytes)

      body = %{
        "model" => request.model,
        "prompt" => request.prompt,
        "response_format" => "base64",
        "n" => request[:count] || 1
      }

      body =
        case optional_string(request[:aspect_ratio]) do
          nil -> body
          aspect -> Map.put(body, "aspect_ratio", aspect)
        end

      body =
        case request[:input_images] || [] do
          [] ->
            body

          [image | _rest] ->
            mime = if image[:mime_type] in [nil, ""], do: "image/jpeg", else: image.mime_type
            data_url = "data:" <> mime <> ";base64," <> Base.encode64(image.data)

            Map.put(body, "subject_reference", [
              %{"type" => "character", "image_file" => data_url}
            ])
        end

      {:ok,
       %{
         url:
           trim(config.base_url) |> String.trim_trailing("/") |> Kernel.<>("/v1/image_generation"),
         model: request.model,
         headers: Map.put(headers, "content-type", "application/json"),
         body: body,
         timeout_ms: request.timeout_ms,
         max_image_bytes: max_image_bytes,
         max_response_bytes:
           Map.get(
             config,
             :max_response_bytes,
             div(max(@max_image_bytes, max_image_bytes) * 9 * 4 + 2, 3) + 1024 * 1024
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

  defp validate_request(request) do
    inputs = request[:input_images] || []

    cond do
      not text?(request[:prompt]) or not text?(request[:model]) or request.model == "" ->
        {:error, :invalid_request}

      not (positive_integer?(request[:timeout_ms]) and request.timeout_ms <= @max_timeout) ->
        {:error, :invalid_timeout}

      not is_nil(request[:count]) and not positive_integer?(request.count) ->
        {:error, :invalid_count}

      not optional_text?(request[:aspect_ratio]) ->
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

      Map.get(config, :provider_id, "minimax") not in ["minimax", "minimax-portal"] ->
        {:error, :invalid_provider}

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
    with {:ok, body} <- http(built, deadline),
         :ok <- check_deadline(deadline),
         {:ok, payload} <- decode_payload(body),
         :ok <- check_base_resp(payload["base_resp"]),
         {:ok, images} <- read_images(payload, built, deadline),
         :ok <- check_deadline(deadline) do
      {:ok, %{images: images, model: built.model}}
    end
  rescue
    _exception -> {:error, :transport}
  catch
    :exit, _reason -> {:error, :transport}
  end

  defp http(built, deadline) do
    timeout = remaining(deadline)

    if timeout == 0 do
      {:error, :timeout}
    else
      Req.Request.new()
      |> Req.Steps.attach()
      |> Req.merge(
        method: :post,
        url: built.url,
        headers: built.headers,
        json: built.body,
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
    {size, chunks} = Req.Response.get_private(response, :minimax_image_body, {0, []})

    if size + byte_size(data) <= limit do
      {:cont,
       {request,
        Req.Response.put_private(
          response,
          :minimax_image_body,
          {size + byte_size(data), [data | chunks]}
        )}}
    else
      {:halt, {request, Req.Response.put_private(response, :minimax_image_limit, true)}}
    end
  end

  defp response({:ok, response}) do
    cond do
      Req.Response.get_private(response, :minimax_image_limit, false) ->
        {:error, :response_too_large}

      response.status not in 200..299 ->
        {:error, {:http_status, response.status}}

      true ->
        {_size, chunks} = Req.Response.get_private(response, :minimax_image_body, {0, []})
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

  defp check_base_resp(%{"status_code" => code} = base_resp) when is_number(code) and code != 0,
    do: {:error, {:api_error, code, base_resp["status_msg"] || ""}}

  defp check_base_resp(_base_resp), do: :ok

  defp read_images(%{"data" => %{"image_base64" => entries}}, built, deadline)
       when is_list(entries) and entries != [] do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn
      {"", _index}, acc ->
        {:cont, acc}

      {entry, index}, {:ok, images} ->
        with :ok <- check_deadline(deadline),
             {:ok, bytes} <- decode_image(entry, built.max_image_bytes) do
          image = %{data: bytes, mime_type: "image/png", filename: "image-#{index + 1}.png"}
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

  defp read_images(_payload, _built, _deadline), do: {:error, :no_images}

  defp decode_image(data, limit) when is_binary(data) do
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

  defp decode_image(_data, _limit), do: {:error, :malformed_response}
end
