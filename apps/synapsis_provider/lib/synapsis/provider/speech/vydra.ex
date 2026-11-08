defmodule Synapsis.Provider.Speech.Vydra do
  @moduledoc """
  Explicitly configured Vydra speech with sequential submission and download.

  Source-shaped config reads only `providers.vydra`; credentials and settings
  are supplied by the host, never the environment. Requests contain verbatim
  UTF-8 text, an audio target, a required positive `:timeout_ms`, optional
  model/voice overrides and an internal absolute monotonic `:deadline_ms`.

  One linked HTTP task owns both stages. Each stage receives a fresh timeout
  clipped to the original native deadline, and the enclosing wait is bounded
  by twice the stage timeout. Native admission, media and delivery remain host
  responsibilities. No polling or preflight output format is inferred.

  Downloaded bytes are opaque. Case-sensitive source output format and normalized
  MIME-derived file extension are independent; media format follows the latter.
  Base URL normalization covers ordinary HTTP(S) forms, not full WHATWG parity.
  """

  @base_url "https://www.vydra.ai/api/v1"
  @model "elevenlabs/tts"
  @voice "21m00Tcm4TlvDq8ikWAM"
  @max_timeout 2_147_483_647
  @max_bytes 16 * 1024 * 1024
  @request_keys [:text, :target, :timeout_ms, :provider_overrides, :deadline_ms]
  @config_keys [:api_key, :base_url, :model, :voice_id, :max_bytes]
  @override_keys [:model, :voice_id, :voiceId]
  @url_keys ~w(audioUrl audioUrls resultUrl resultUrls outputUrl outputUrls url urls)
  @recurse_keys ~w(output outputs result results data asset assets)
  @js_space "[\\x{0009}-\\x{000D}\\x{0020}\\x{00A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}]"
  @js_trim Regex.compile!("\\A#{@js_space}+|#{@js_space}+\\z", "u")

  def models, do: [@model]
  def voices, do: [%{id: @voice, name: "Rachel"}]

  @doc "Normalize explicit source-shaped configuration without environment lookup."
  def resolve_config(raw_config) do
    root = record(raw_config)
    providers = record(root["providers"])
    raw = record(providers["vydra"])

    %{
      base_url: normalize_base(raw["baseUrl"]),
      model: trim(raw["model"]) || @model,
      voice_id: trim(raw["voiceId"]) || @voice
    }
    |> put_optional(:api_key, trim(raw["apiKey"]))
  end

  @spec build_request(map(), map()) :: {:ok, map()} | {:error, term()}
  def build_request(request, config) do
    with :ok <- options(request, @request_keys, :invalid_request),
         :ok <- options(config, @config_keys, :invalid_config),
         true <- is_binary(request[:text]) and String.valid?(request.text),
         true <- request[:target] in [:audio_file, :voice_note],
         true <- is_nil(request[:deadline_ms]) or is_integer(request[:deadline_ms]),
         {:ok, timeout} <- timeout(request[:timeout_ms]),
         {:ok, limit} <- byte_limit(config),
         overrides = Map.get(request, :provider_overrides, %{}),
         :ok <- options(overrides, @override_keys, :invalid_overrides),
         api_key when is_binary(api_key) <- trim(config[:api_key]) do
      model = trim(overrides[:model]) || trim(config[:model]) || @model

      voice =
        trim(overrides[:voice_id] || overrides[:voiceId]) || trim(config[:voice_id]) || @voice

      {:ok,
       %{
         url: normalize_base(config[:base_url]) <> "/models/" <> model,
         body: %{"text" => request.text, "voice_id" => voice},
         timeout_ms: timeout,
         max_bytes: limit
       }
       |> put_optional(:deadline_ms, request[:deadline_ms])}
    else
      false -> {:error, :invalid_request}
      nil -> {:error, :invalid_config}
      error -> error
    end
  end

  @spec synthesize(map(), map()) :: {:ok, map()} | {:error, term()}
  def synthesize(request, config) do
    with {:ok, built} <- build_request(request, config) do
      wait = min(2 * built.timeout_ms, @max_timeout)
      wait = if built[:deadline_ms], do: min(wait, remaining(built.deadline_ms)), else: wait
      task = Task.async(fn -> perform(built, trim(config[:api_key])) end)

      case Task.yield(task, wait) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        nil -> {:error, :timeout}
        {:exit, _reason} -> {:error, :transport}
      end
    end
  end

  defp normalize_base(value) do
    with value when is_binary(value) <- trim(value),
         {:ok, %URI{scheme: scheme, host: host} = uri} <- URI.new(value),
         true <- scheme in ["http", "https"] and is_binary(host) and host != "" do
      host = String.downcase(host)
      path = String.trim_trailing(uri.path || "", "/")

      %{
        uri
        | host: if(host == "vydra.ai", do: "www.vydra.ai", else: host),
          path: if(path == "", do: "/api/v1", else: path)
      }
      |> URI.to_string()
      |> String.trim_trailing("/")
    else
      _ -> @base_url
    end
  end

  defp timeout(value) when is_integer(value) and value > 0,
    do: {:ok, min(value, @max_timeout)}

  defp timeout(_), do: {:error, :invalid_timeout}

  defp byte_limit(config) do
    case Map.get(config, :max_bytes, @max_bytes) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, :invalid_max_bytes}
    end
  end

  defp options(value, keys, error) when is_map(value) and not is_struct(value) do
    if Enum.all?(Map.keys(value), &(&1 in keys)), do: :ok, else: {:error, error}
  end

  defp options(_, _, error), do: {:error, error}
  defp record(value) when is_map(value) and not is_struct(value), do: value
  defp record(_), do: %{}

  defp trim(value) when is_binary(value) do
    if String.valid?(value) do
      case Regex.replace(@js_trim, value, "") do
        "" -> nil
        value -> value
      end
    end
  end

  defp trim(_), do: nil
  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
  defp now_ms, do: System.monotonic_time(:millisecond)
  defp remaining(deadline), do: max(0, deadline - now_ms())

  defp stage_deadline(built) do
    deadline = now_ms() + built.timeout_ms
    if built[:deadline_ms], do: min(deadline, built.deadline_ms), else: deadline
  end

  defp within_deadline(deadline) do
    if remaining(deadline) > 0, do: :ok, else: {:error, :timeout}
  end

  defp perform(built, api_key) do
    headers = [{"authorization", "Bearer " <> api_key}, {"content-type", "application/json"}]

    with {:ok, url} <- submit(built, headers),
         {:ok, result} <- download(url, built, headers) do
      {:ok, result}
    end
  rescue
    _exception -> {:error, :transport}
  catch
    :exit, _reason -> {:error, :transport}
  end

  defp submit(built, headers) do
    deadline = stage_deadline(built)

    with {:ok, response} <-
           http(
             :post,
             built.url,
             headers,
             [body: Jason.encode!(built.body)],
             @max_bytes,
             deadline
           ),
         {:ok, payload} <- decode_json(response.body),
         urls = result_urls(payload),
         :ok <- within_deadline(deadline),
         [url | _] <- urls do
      {:ok, url}
    else
      [] -> {:error, :malformed_response}
      {:error, _reason} = error -> error
    end
  end

  defp decode_json(<<0xEF, 0xBB, 0xBF, body::binary>>), do: decode_json(body)

  defp decode_json(body) do
    case Jason.decode(body) do
      {:ok, payload} -> {:ok, payload}
      _ -> {:error, :malformed_response}
    end
  end

  defp result_urls(payload) do
    {_seen, reversed} = visit(payload, 0, {MapSet.new(), []})
    Enum.reverse(reversed)
  end

  defp visit(_value, depth, acc) when depth > 5, do: acc

  defp visit(values, depth, acc) when is_list(values),
    do: Enum.reduce(values, acc, &visit(&1, depth + 1, &2))

  defp visit(value, depth, acc) when is_map(value) do
    acc = Enum.reduce(@url_keys, acc, &url_value(value[&1], &2))
    Enum.reduce(@recurse_keys, acc, &visit(value[&1], depth + 1, &2))
  end

  defp visit(_value, _depth, acc), do: acc

  defp url_value(values, acc) when is_list(values),
    do: Enum.reduce(values, acc, &url_value/2)

  defp url_value(value, {seen, urls} = acc) do
    case trim(value) do
      nil ->
        acc

      url ->
        if Regex.match?(~r/\Ahttps?:\/\//iu, url) and not MapSet.member?(seen, url),
          do: {MapSet.put(seen, url), [url | urls]},
          else: acc
    end
  end

  defp download(url, built, headers) do
    deadline = stage_deadline(built)
    headers = if origin(url) == origin(built.url), do: headers, else: []

    with {:ok, response} <- http(:get, url, headers, [], built.max_bytes, deadline) do
      mime = response.headers |> Map.get("content-type", []) |> Enum.join(", ") |> trim()
      mime = mime || "audio/mpeg"
      normalized = mime |> String.split(";", parts: 2) |> hd()
      normalized = String.downcase(trim(normalized) || "")
      media_format = if normalized in ~w(audio/wav audio/wave audio/x-wav), do: "wav", else: "mp3"

      with :ok <- within_deadline(deadline) do
        {:ok,
         %{
           audio: response.body,
           output_format: if(String.contains?(mime, "wav"), do: "wav", else: "mp3"),
           file_extension: "." <> media_format,
           media_format: media_format,
           voice_compatible: false
         }}
      end
    end
  end

  defp origin(url) do
    uri = URI.parse(url)
    {String.downcase(uri.scheme || ""), String.downcase(uri.host || ""), uri.port}
  end

  defp http(method, url, headers, options, limit, deadline) do
    case remaining(deadline) do
      0 ->
        {:error, :timeout}

      timeout ->
        Req.Request.new()
        |> Req.Steps.attach()
        |> Req.merge(
          options ++
            [
              method: method,
              url: url,
              headers: headers,
              raw: true,
              compressed: false,
              into: fn event, pair -> collect(event, pair, limit, deadline) end,
              retry: false,
              redirect: false,
              receive_timeout: timeout,
              request_timeout: timeout,
              finch: [pool_timeout: timeout]
            ]
        )
        |> Req.request()
        |> response(deadline)
    end
  end

  defp collect({:data, data}, {request, response}, limit, deadline) do
    {size, chunks} = Req.Response.get_private(response, :vydra_speech_body, {0, []})

    cond do
      remaining(deadline) == 0 ->
        {:halt, {request, Req.Response.put_private(response, :vydra_speech_timeout, true)}}

      size + byte_size(data) > limit ->
        {:halt, {request, Req.Response.put_private(response, :vydra_speech_limit, true)}}

      true ->
        {:cont,
         {request,
          Req.Response.put_private(
            response,
            :vydra_speech_body,
            {size + byte_size(data), [data | chunks]}
          )}}
    end
  end

  defp response({:ok, response}, deadline) do
    cond do
      Req.Response.get_private(response, :vydra_speech_timeout, false) or remaining(deadline) == 0 ->
        {:error, :timeout}

      Req.Response.get_private(response, :vydra_speech_limit, false) ->
        {:error, :response_too_large}

      response.status not in 200..299 ->
        {:error, {:http_status, response.status}}

      true ->
        {_size, chunks} = Req.Response.get_private(response, :vydra_speech_body, {0, []})

        {:ok,
         %{body: chunks |> Enum.reverse() |> IO.iodata_to_binary(), headers: response.headers}}
    end
  end

  defp response({:error, _reason}, _deadline), do: {:error, :transport}
end
