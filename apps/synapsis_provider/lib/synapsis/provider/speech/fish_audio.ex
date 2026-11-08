defmodule Synapsis.Provider.Speech.FishAudio do
  @moduledoc """
  Explicit Fish Audio speech services, with opaque target-selected audio.

  Source-shaped config and Talk callbacks are pure. HTTP receives only supplied
  credentials and settings; saved identity and current credentials belong to
  `Synapsis.Providers`. Native admission, media publication and replay remain with
  the existing TTS effect owner. Streaming handles are invocation-local resources:
  consume them through EOF, then explicitly release them. No automatic Talk,
  channel or telephony platform, authentication discovery or directive dispatch
  is installed by these service callbacks.
  """

  alias __MODULE__.Stream

  @base_url "https://api.fish.audio"
  @models ~w(drama-3 drama-3-preview s2.1-pro-free s2.1-pro s2-pro s1)
  @model "s2.1-pro"
  @timeout 240_000
  @max_timeout 2_147_483_647
  @max_bytes 16 * 1024 * 1024
  @voice_bytes 2 * 1024 * 1024
  @request_keys ~w(text target timeout_ms provider_overrides deadline_ms)a
  @config_keys ~w(api_key base_url model reference_id latency speed temperature top_p normalize max_bytes)a
  @override_keys ~w(model model_id speaker_voice_id voice_id reference_id latency speed temperature top_p normalize)a
  @js_space "[\\x{0009}-\\x{000D}\\x{0020}\\x{00A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}]"
  @js_trim Regex.compile!("\\A#{@js_space}+|#{@js_space}+\\z", "u")

  def models, do: @models
  def default_timeout_ms, do: @timeout

  def metadata do
    %{
      id: "fish-audio",
      label: "Fish Audio",
      auto_select_order: 28,
      default_model: @model,
      default_timeout_ms: @timeout,
      models: @models
    }
  end

  @doc "Normalize only providers.fish-audio, retaining source nullish alias precedence."
  def resolve_config(raw_config) do
    root = record(raw_config)
    providers = record(root["providers"])
    raw = record(providers["fish-audio"])

    %{
      base_url: normalize_base(raw["baseUrl"]),
      model: normalize_model(coalesce(raw["model"], raw["modelId"])),
      latency: normalize_latency(raw["latency"])
    }
    |> put_optional(:api_key, trim(raw["apiKey"]))
    |> put_optional(:reference_id, reference(raw))
    |> put_optional(:speed, number(raw["speed"], 0.5, 2))
    |> put_optional(:temperature, number(raw["temperature"], 0, 1))
    |> put_optional(:top_p, number(coalesce(raw["topP"], raw["top_p"]), 0, 1))
    |> put_optional(:normalize, boolean(raw["normalize"]))
  end

  @doc "Overlay Talk connection, model, reference, latency and speed on base TTS settings."
  def resolve_talk_config(base_tts_config, talk_provider_config) do
    talk = record(talk_provider_config)
    base = resolve_config(base_tts_config)

    base =
      if Map.has_key?(talk, "apiKey"),
        do: base |> Map.delete(:api_key) |> put_optional(:api_key, trim(talk["apiKey"])),
        else: base

    base
    |> put_optional(:base_url, if(trim(talk["baseUrl"]), do: normalize_base(talk["baseUrl"])))
    |> put_optional(:model, optional_model(coalesce(talk["modelId"], talk["model"])))
    |> put_optional(:reference_id, reference(talk))
    |> put_optional(:latency, optional_latency(talk["latency"]))
    |> put_optional(:speed, number(talk["speed"], 0.5, 2))
  end

  @doc "Talk per-call overrides contain only model, reference and speed."
  def resolve_talk_overrides(params) do
    raw = record(params)

    %{}
    |> put_optional(:model, optional_model(coalesce(raw["modelId"], raw["model"])))
    |> put_optional(:reference_id, reference(raw))
    |> put_optional(:speed, number(raw["speed"], 0.5, 2))
  end

  @doc "Source directive callback; callers retain policy and dispatch authority."
  def parse_directive_token(context) do
    key = context[:key] || context["key"]
    value = Map.get(context, :value, context["value"])
    policy = record(context[:policy] || context["policy"])

    rule =
      cond do
        key in ~w(voice voiceid voice_id referenceid reference_id fish_voice fishaudio_voice) ->
          {:reference_id, :allowVoice}

        key in ~w(model modelid model_id fish_model fishaudio_model) ->
          {:model, :allowModelId}

        key in ~w(speed fish_speed) ->
          {:speed, :allowVoiceSettings}

        key in ~w(temperature fish_temperature) ->
          {:temperature, :allowVoiceSettings}

        key in ~w(top_p topp fish_top_p) ->
          {:top_p, :allowVoiceSettings}

        key in ~w(latency fish_latency) ->
          {:latency, :allowVoiceSettings}

        key in ~w(normalize fish_normalize) ->
          {:normalize, :allowNormalization}

        true ->
          nil
      end

    case rule do
      nil ->
        %{handled: false}

      {field, flag} ->
        if Map.get(policy, flag, Map.get(policy, Atom.to_string(flag), false)),
          do: directive_value(field, value),
          else: %{handled: true}
    end
  rescue
    error in ArgumentError -> %{handled: true, warnings: ["Error: " <> Exception.message(error)]}
  end

  @spec build_request(map(), map()) :: {:ok, map()} | {:error, term()}
  def build_request(request, config) do
    with :ok <- options(request, @request_keys, :invalid_request),
         :ok <- options(config, @config_keys, :invalid_config),
         true <- is_binary(request[:text]) and String.valid?(request.text),
         true <- request[:target] in [:audio_file, :voice_note, :telephony],
         {:ok, timeout} <- timeout(request[:timeout_ms]),
         {:ok, limit} <- byte_limit(config),
         overrides = Map.get(request, :provider_overrides, %{}),
         :ok <- options(overrides, @override_keys, :invalid_overrides),
         {:ok, base_url, api_key} <- connection(config),
         {:ok, deadline} <- deadline(timeout, request[:deadline_ms]) do
      settings =
        %{
          model: normalize_model(config[:model]),
          latency: normalize_latency(config[:latency])
        }
        |> put_optional(:reference_id, trim(config[:reference_id]))
        |> put_optional(:speed, number(config[:speed], 0.5, 2))
        |> put_optional(:temperature, number(config[:temperature], 0, 1))
        |> put_optional(:top_p, number(config[:top_p], 0, 1))
        |> put_optional(:normalize, boolean(config[:normalize]))
        |> put_optional(:model, optional_model(coalesce(overrides[:model], overrides[:model_id])))
        |> put_optional(
          :reference_id,
          trim(
            coalesce(
              overrides[:speaker_voice_id],
              coalesce(overrides[:voice_id], overrides[:reference_id])
            )
          )
        )
        |> put_optional(:latency, optional_latency(overrides[:latency]))
        |> put_optional(:speed, number(overrides[:speed], 0.5, 2))
        |> put_optional(:temperature, number(overrides[:temperature], 0, 1))
        |> put_optional(:top_p, number(overrides[:top_p], 0, 1))
        |> put_optional(:normalize, boolean(overrides[:normalize]))

      output = output(request.target)

      body =
        %{
          "text" => request.text,
          "format" => output.output_format,
          "sample_rate" => sample_rate(request.target),
          "latency" => settings.latency
        }
        |> put_optional("reference_id", settings[:reference_id])
        |> put_optional("prosody", if(settings[:speed], do: %{"speed" => settings.speed}))
        |> put_optional("temperature", settings[:temperature])
        |> put_optional("top_p", settings[:top_p])
        |> put_optional("normalize", settings[:normalize])

      {:ok,
       Map.merge(output, %{
         url: base_url <> "/v1/tts",
         headers: [
           {"authorization", "Bearer " <> api_key},
           {"content-type", "application/json"},
           {"model", settings.model}
         ],
         body: body,
         timeout_ms: timeout,
         deadline_ms: deadline,
         resolved_config:
           Map.merge(settings, %{api_key: api_key, base_url: base_url, max_bytes: limit}),
         max_bytes: limit
       })}
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  rescue
    _error in ArgumentError -> {:error, :invalid_config}
  end

  @spec synthesize(map(), map()) :: {:ok, map()} | {:error, term()}
  def synthesize(request, config) do
    with {:ok, built} <- build_request(request, config),
         {:ok, audio} <-
           http(
             :post,
             built.url,
             built.headers,
             Jason.encode!(built.body),
             built.timeout_ms,
             built.deadline_ms,
             built.max_bytes
           ) do
      {:ok,
       built
       |> Map.take([:output_format, :file_extension, :voice_compatible])
       |> Map.put(:audio, audio)}
    end
  end

  @spec stream_synthesize(map(), map()) :: {:ok, map()} | {:error, term()}
  def stream_synthesize(request, config) do
    with {:ok, built} <- build_request(request, config),
         {:ok, stream} <- Stream.open(%{built | max_bytes: min(built.max_bytes, @max_bytes)}) do
      {:ok,
       built
       |> Map.take([:output_format, :file_extension, :voice_compatible])
       |> Map.put(:stream, stream)}
    end
  end

  @spec synthesize_telephony(map(), map()) :: {:ok, map()} | {:error, term()}
  def synthesize_telephony(request, config) do
    with {:ok, response} <- synthesize(Map.put(request, :target, :telephony), config) do
      {:ok, %{audio: response.audio, output_format: "pcm", sample_rate: 8_000}}
    end
  end

  @doc "Fetch owned pages sequentially, then merge the first public page, owned IDs first."
  def list_voices(request, config) do
    with :ok <- options(request, ~w(api_key base_url timeout_ms deadline_ms)a, :invalid_request),
         {:ok, timeout} <- timeout(Map.get(request, :timeout_ms, @timeout)),
         {:ok, base, key} <-
           connection(%{
             api_key: trim(request[:api_key]) || config[:api_key],
             base_url: trim(request[:base_url]) || config[:base_url]
           }),
         {:ok, whole_deadline} <- deadline(21 * timeout, request[:deadline_ms]),
         {:ok, own} <- own_voices(base, key, timeout, whole_deadline, 1, []) do
      public =
        case voice_page(base, key, timeout, whole_deadline, false, 1) do
          {:ok, payload} -> parse_voices(payload)
          {:error, _} -> []
        end

      {:ok, Enum.uniq_by(own ++ public, & &1.id)}
    end
  end

  defp own_voices(base, key, timeout, deadline, page, own) do
    with {:ok, payload} <- voice_page(base, key, timeout, deadline, true, page) do
      items = if is_list(payload["items"]), do: payload["items"], else: []
      own = own ++ parse_voices(payload)
      total = payload["total"]

      if page < 20 and length(items) == 100 and (is_nil(total) or length(own) < total),
        do: own_voices(base, key, timeout, deadline, page + 1, own),
        else: {:ok, own}
    end
  end

  defp voice_page(base, key, timeout, whole_deadline, self?, page) do
    query = [{"type", "tts"}, {"page_size", "100"}, {"page_number", to_string(page)}]
    query = query ++ if(self?, do: [{"self", "true"}], else: [{"sort_by", "score"}])

    with {:ok, page_deadline} <- deadline(timeout, whole_deadline),
         duration when duration > 0 <- remaining(page_deadline),
         {:ok, bytes} <-
           http(
             :get,
             base <> "/model?" <> URI.encode_query(query),
             [{"authorization", "Bearer " <> key}],
             nil,
             duration,
             page_deadline,
             @voice_bytes
           ),
         {:ok, payload} when is_map(payload) <- Jason.decode(bytes) do
      {:ok, payload}
    else
      value when is_integer(value) -> {:error, :timeout}
      {:ok, _} -> {:error, :invalid_response}
      error -> error
    end
  end

  defp parse_voices(payload) do
    items = if is_list(payload["items"]), do: payload["items"], else: []

    Enum.flat_map(items, fn item ->
      item = record(item)

      case trim(item["_id"]) do
        nil ->
          []

        id ->
          languages = string_list(item["languages"])
          tags = string_list(item["tags"])

          [
            %{id: id}
            |> put_optional(:name, trim(item["title"]))
            |> put_optional(:description, trim(item["description"]))
            |> put_optional(:category, trim(item["visibility"]))
            |> put_optional(:locale, List.first(languages))
            |> put_optional(:personalities, if(tags != [], do: tags))
          ]
      end
    end)
  end

  # The task's outer wait includes pool acquisition and the complete body. Req's
  # individual timers are finite too; successful native calls preserve their
  # selected per-operation duration while the wait clips to the actual deadline.
  defp http(method, url, headers, body, duration, deadline, limit) do
    task = Task.async(fn -> perform(method, url, headers, body, duration, limit) end)

    case Task.yield(task, remaining(deadline)) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
      {:exit, _} -> {:error, :transport}
    end
  end

  defp perform(method, url, headers, body, duration, limit) do
    Req.Request.new()
    |> Req.Steps.attach()
    |> Req.merge(
      method: method,
      url: url,
      headers: headers,
      body: body,
      raw: true,
      compressed: false,
      retry: false,
      redirect: false,
      receive_timeout: duration,
      request_timeout: duration,
      finch: [pool_timeout: duration],
      into: fn event, pair -> collect(event, pair, limit) end
    )
    |> Req.request()
    |> response(method)
  rescue
    _ -> {:error, :transport}
  catch
    :exit, _ -> {:error, :transport}
  end

  defp collect({:data, bytes}, {request, response}, limit) do
    {size, chunks} = Req.Response.get_private(response, :fish_body, {0, []})

    if size + byte_size(bytes) <= limit,
      do:
        {:cont,
         {request,
          Req.Response.put_private(
            response,
            :fish_body,
            {size + byte_size(bytes), [bytes | chunks]}
          )}},
      else: {:halt, {request, Req.Response.put_private(response, :fish_limit, true)}}
  end

  defp response({:ok, response}, method) do
    type = response |> Req.Response.get_header("content-type") |> List.first()

    cond do
      Req.Response.get_private(response, :fish_limit, false) ->
        {:error, :response_too_large}

      response.status not in 200..299 ->
        {:error, {:http_status, response.status}}

      method == :post and not audio_type?(type) ->
        {:error, :invalid_audio}

      true ->
        {size, chunks} = Req.Response.get_private(response, :fish_body, {0, []})

        if method == :post and size == 0,
          do: {:error, :invalid_audio},
          else: {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  defp response({:error, _}, _method), do: {:error, :transport}
  defp audio_type?(nil), do: true

  defp audio_type?(type) do
    type = type |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()

    String.starts_with?(type, "audio/") or
      type in ["application/octet-stream", "binary/octet-stream", "application/ogg"]
  end

  defp output(:voice_note),
    do: %{output_format: "opus", file_extension: ".opus", voice_compatible: true}

  defp output(:telephony),
    do: %{output_format: "pcm", file_extension: ".pcm", voice_compatible: false}

  defp output(:audio_file),
    do: %{output_format: "mp3", file_extension: ".mp3", voice_compatible: false}

  defp sample_rate(:voice_note), do: 48_000
  defp sample_rate(:telephony), do: 8_000
  defp sample_rate(:audio_file), do: 44_100

  defp connection(config) do
    base = normalize_base(config[:base_url])

    with key when is_binary(key) <- trim(config[:api_key]),
         {:ok, %URI{scheme: scheme, host: host}}
         when scheme in ["http", "https"] and is_binary(host) and host != "" <- URI.new(base) do
      {:ok, base, key}
    else
      _ -> {:error, :invalid_config}
    end
  end

  defp timeout(value) when is_integer(value) and value > 0 and value <= @max_timeout,
    do: {:ok, value}

  defp timeout(_), do: {:error, :invalid_timeout}

  defp byte_limit(config) do
    case Map.get(config, :max_bytes, @max_bytes) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, :invalid_max_bytes}
    end
  end

  defp deadline(duration, nil), do: {:ok, now() + duration}

  defp deadline(duration, absolute) when is_integer(absolute) do
    deadline = min(now() + duration, absolute)
    if remaining(deadline) > 0, do: {:ok, deadline}, else: {:error, :timeout}
  end

  defp deadline(_, _), do: {:error, :invalid_deadline}
  defp remaining(deadline), do: max(0, deadline - now())
  defp now, do: System.monotonic_time(:millisecond)

  defp options(value, keys, error) when is_map(value) and not is_struct(value),
    do: if(Enum.all?(Map.keys(value), &(&1 in keys)), do: :ok, else: {:error, error})

  defp options(_, _, error), do: {:error, error}
  defp normalize_base(value), do: String.trim_trailing(trim(value) || @base_url, "/")

  defp normalize_model(value) do
    model = trim(value) || @model

    if model in @models,
      do: model,
      else: raise(ArgumentError, "invalid Fish Audio model \"#{model}\"")
  end

  defp normalize_latency(value) do
    latency = if(trim(value), do: String.downcase(trim(value)), else: "balanced")

    if latency in ~w(low balanced normal),
      do: latency,
      else: raise(ArgumentError, "invalid Fish Audio latency \"#{latency}\"")
  end

  defp optional_model(value), do: if(trim(value), do: normalize_model(value))
  defp optional_latency(value), do: if(trim(value), do: normalize_latency(value))

  defp reference(raw),
    do: trim(coalesce(raw["speakerVoiceId"], coalesce(raw["voiceId"], raw["referenceId"])))

  defp coalesce(nil, fallback), do: fallback
  defp coalesce(value, _), do: value

  defp number(value, low, high) when is_number(value) and value >= low and value <= high,
    do: value

  defp number(_, _, _), do: nil
  defp boolean(value) when is_boolean(value), do: value
  defp boolean(_), do: nil
  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
  defp record(value) when is_map(value) and not is_struct(value), do: value
  defp record(_), do: %{}

  defp string_list(value) when is_list(value),
    do: Enum.flat_map(value, fn value -> if value = trim(value), do: [value], else: [] end)

  defp string_list(_), do: []

  defp trim(value) when is_binary(value) do
    if String.valid?(value) do
      case Regex.replace(@js_trim, value, "") do
        "" -> nil
        value -> value
      end
    end
  end

  defp trim(_), do: nil

  defp directive_value(:reference_id, value),
    do: %{handled: true, overrides: %{reference_id: value}}

  defp directive_value(:model, value),
    do: %{handled: true, overrides: %{model: normalize_model(value)}}

  defp directive_value(:latency, value),
    do: %{handled: true, overrides: %{latency: normalize_latency(value)}}

  defp directive_value(:normalize, value) do
    normalized =
      if is_binary(value),
        do: value |> trim() |> then(fn value -> if value, do: String.downcase(value) end),
        else: value

    cond do
      normalized in [true, "true", "1", "yes", "on"] ->
        %{handled: true, overrides: %{normalize: true}}

      normalized in [false, "false", "0", "no", "off"] ->
        %{handled: true, overrides: %{normalize: false}}

      true ->
        %{handled: true, warnings: ["invalid Fish Audio normalize \"#{value}\""]}
    end
  end

  defp directive_value(field, value) do
    {low, high} = if field == :speed, do: {0.5, 2}, else: {0, 1}
    normalized = directive_number(value, low, high)
    label = if field == :top_p, do: "top_p", else: Atom.to_string(field)

    if is_nil(normalized),
      do: %{handled: true, warnings: ["invalid Fish Audio #{label} \"#{value}\""]},
      else: %{handled: true, overrides: %{field => normalized}}
  end

  defp directive_number(value, low, high) when is_number(value), do: number(value, low, high)

  defp directive_number(value, low, high) do
    token = trim(value)

    if token && Regex.match?(~r/\A[+-]?(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?\z/i, token) do
      token =
        token
        |> String.replace(~r/\A([+-]?)\./, "\\g{1}0.")
        |> String.replace(~r/\.(e|\z)/i, ".0\\g{1}")

      case Float.parse(token) do
        {value, ""} -> number(value, low, high)
        _ -> nil
      end
    end
  end
end
