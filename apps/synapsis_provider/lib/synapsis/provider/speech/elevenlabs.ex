defmodule Synapsis.Provider.Speech.ElevenLabs do
  @moduledoc """
  Explicitly configured ElevenLabs speech services.

  Raw config and Talk callbacks accept source-shaped string keys and return
  atom-key host config. Raw config reads only `providers.elevenlabs`. These pure
  callbacks do not discover credentials, select providers or install a consumer.

  `build_request/2` and `synthesize/2` take atom-key maps. Requests contain `:text`,
  `:target` (`:audio_file` or `:voice_note`), optional `:timeout_ms`, optional
  `:deadline_ms` and `:provider_overrides`. The dedicated telephony API always
  returns fixed PCM at 22050 Hz. Config contains `:api_key`, optional `:base_url`,
  `:voice_id`, `:model_id`, `:seed`, `:apply_text_normalization`, `:language_code`,
  `:voice_settings` and `:max_bytes`. Nested voice settings accept snake-case atom
  or string keys. Overrides support those speech options plus `:output_format`
  and `:latency_tier`, without endpoint or credential overrides.

  Output retains the vendor `:output_format`, source `:file_extension` and
  `:voice_compatible` metadata. Only MP3, Opus and WAV expose `:media_format` for
  native publication; other formats remain opaque bytes for the caller. This
  service does not select providers, read environment variables, publish media or
  own the native tool lifecycle. Call HTTP operations from an execution task.
  Streaming uses a consumer-owned handle: read through EOF and explicitly release
  with `Synapsis.Provider.Speech.ElevenLabs.Stream.release/1` in `after`.
  """

  alias __MODULE__.Stream

  @base_url "https://api.elevenlabs.io"
  @voice_id "pMsXgVXv3BLzUgSXRplE"
  @model_id "eleven_multilingual_v2"
  @models ~w(eleven_v3 eleven_multilingual_v2 eleven_flash_v2_5 eleven_flash_v2 eleven_turbo_v2_5 eleven_monolingual_v1)
  @request_keys [:text, :target, :timeout_ms, :deadline_ms, :provider_overrides]
  @speech_keys [
    :voice_id,
    :model_id,
    :seed,
    :apply_text_normalization,
    :language_code,
    :voice_settings
  ]
  @config_keys [:api_key, :base_url, :max_bytes | @speech_keys]
  @override_keys [:output_format, :latency_tier | @speech_keys]
  @voice_settings %{
    stability: 0.5,
    similarity_boost: 0.75,
    style: 0,
    use_speaker_boost: true,
    speed: 1
  }
  @max_timeout 2_147_483_647
  @max_bytes 16 * 1024 * 1024
  @families ~w(opus mp3 pcm ulaw alaw wav)
  @output_keys ~w(output_format file_extension voice_compatible media_format sample_rate)a
  @js_space "[\\x{0009}-\\x{000D}\\x{0020}\\x{00A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}]"
  @js_trim Regex.compile!("\\A#{@js_space}+|#{@js_space}+\\z", "u")

  def models, do: @models

  def metadata do
    %{
      id: "elevenlabs",
      label: "ElevenLabs",
      auto_select_order: 20,
      default_model: @model_id,
      models: @models
    }
  end

  @doc "Normalize only the nested providers.elevenlabs source configuration."
  def resolve_config(raw_config) do
    raw = raw_config |> record() |> Map.get("providers") |> record() |> Map.get("elevenlabs")
    raw = record(raw)

    %{
      base_url: normalize_base(raw["baseUrl"]),
      voice_id: trim(raw["voiceId"]) || @voice_id,
      model_id: model(trim(raw["modelId"])) || @model_id,
      voice_settings: Map.merge(@voice_settings, source_voice_settings(raw["voiceSettings"]))
    }
    |> optional(:api_key, trim(raw["apiKey"]))
    |> optional(:seed, integer(raw["seed"], 0, 4_294_967_295))
    |> optional(:apply_text_normalization, trim(raw["applyTextNormalization"]))
    |> optional(:language_code, trim(raw["languageCode"]))
  end

  @doc "Overlay explicit Talk settings on the normalized nested TTS base."
  def resolve_talk_config(base_tts_config, talk_provider_config) do
    base = resolve_config(base_tts_config)
    talk = record(talk_provider_config)

    base
    |> optional(:api_key, trim(talk["apiKey"]))
    |> optional(:base_url, if(trim(talk["baseUrl"]), do: normalize_base(talk["baseUrl"])))
    |> optional(:voice_id, trim(talk["voiceId"]))
    |> optional(:model_id, model(trim(talk["modelId"])))
    |> optional(:seed, integer(talk["seed"], 0, 4_294_967_295))
    |> optional(
      :apply_text_normalization,
      normalized_optional(talk["applyTextNormalization"], &normalization/1)
    )
    |> optional(:language_code, normalized_optional(talk["languageCode"], &language/1))
    |> Map.put(
      :voice_settings,
      Map.merge(base.voice_settings, source_voice_settings(talk["voiceSettings"]))
    )
  end

  @doc "Translate flat Talk parameters into explicit per-call speech overrides."
  def resolve_talk_overrides(params) do
    params = record(params)

    settings =
      source_voice_settings(%{
        "speed" => params["speed"],
        "stability" => params["stability"],
        "similarityBoost" => params["similarity"],
        "style" => params["style"],
        "useSpeakerBoost" => params["speakerBoost"]
      })

    %{}
    |> optional(:voice_id, trim(params["voiceId"]))
    |> optional(:model_id, model(trim(params["modelId"])))
    |> optional(:output_format, trim(params["outputFormat"]))
    |> optional(:seed, integer(params["seed"], 0, 4_294_967_295))
    |> optional(
      :apply_text_normalization,
      normalized_optional(params["normalize"], &normalization/1)
    )
    |> optional(:language_code, normalized_optional(params["language"], &language/1))
    |> optional(:latency_tier, integer(params["latencyTier"], 0, 4))
    |> optional(:voice_settings, if(map_size(settings) > 0, do: settings))
  end

  @spec build_request(map(), map()) :: {:ok, map()} | {:error, term()}
  def build_request(request, config), do: build(request, config, :buffered)

  @spec build_stream_request(map(), map()) :: {:ok, map()} | {:error, term()}
  def build_stream_request(request, config), do: build(request, config, :stream)

  @spec build_telephony_request(map(), map()) :: {:ok, map()} | {:error, term()}
  def build_telephony_request(request, config), do: build(request, config, :telephony)

  defp build(request, config, operation) do
    with :ok <- options(request, @request_keys, :invalid_request),
         :ok <- options(config, @config_keys, :invalid_config),
         true <- is_binary(request[:text]) and String.valid?(request.text),
         true <- operation == :telephony or request[:target] in [:audio_file, :voice_note],
         {:ok, timeout} <- timeout(request),
         {:ok, deadline, transport_deadline} <- deadline(timeout, request[:deadline_ms]),
         {:ok, limit} <- byte_limit(config),
         overrides = Map.get(request, :provider_overrides, %{}),
         :ok <- options(overrides, @override_keys, :invalid_overrides),
         {:ok, resolved} <- resolve(config, overrides) do
      format =
        if operation == :telephony,
          do: "pcm_22050",
          else:
            trim(overrides[:output_format]) ||
              if(request.target == :voice_note, do: "opus_48000_64", else: "mp3_44100_128")

      query = [{"output_format", format}]

      query =
        if operation != :telephony and not is_nil(resolved.latency_tier) and
             String.downcase(resolved.model_id) != "eleven_v3",
           do: query ++ [{"optimize_streaming_latency", resolved.latency_tier}],
           else: query

      body =
        %{
          "text" => request.text,
          "model_id" => resolved.model_id,
          "voice_settings" =>
            Map.new(resolved.voice_settings, fn {key, value} -> {to_string(key), value} end)
        }
        |> optional("seed", resolved.seed)
        |> optional("apply_text_normalization", resolved.apply_text_normalization)
        |> optional("language_code", resolved.language_code)

      output =
        if operation == :telephony,
          do: %{output_format: format, sample_rate: 22_050},
          else: output(format)

      suffix = if operation == :stream, do: "/stream", else: ""
      headers = [{"xi-api-key", trim(config[:api_key])}, {"content-type", "application/json"}]

      headers =
        if String.starts_with?(String.downcase(format), "mp3_"),
          do: [{"accept", "audio/mpeg"} | headers],
          else: headers

      {:ok,
       Map.merge(output, %{
         url:
           resolved.base_url <>
             "/v1/text-to-speech/" <>
             resolved.voice_id <> suffix <> "?" <> URI.encode_query(query),
         headers: headers,
         body: body,
         timeout_ms: timeout,
         deadline_ms: deadline,
         transport_deadline_ms: transport_deadline,
         max_bytes: limit
       })}
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  @spec synthesize(map(), map()) :: {:ok, map()} | {:error, term()}
  def synthesize(request, config) do
    with {:ok, built} <- build_request(request, config), do: buffered(built)
  end

  @spec synthesize_telephony(map(), map()) :: {:ok, map()} | {:error, term()}
  def synthesize_telephony(request, config) do
    with {:ok, built} <- build_telephony_request(request, config), do: buffered(built)
  end

  @spec stream_synthesize(map(), map()) :: {:ok, map()} | {:error, term()}
  def stream_synthesize(request, config) do
    with {:ok, built} <- build_stream_request(request, config),
         {:ok, stream} <- Stream.open(%{built | max_bytes: min(built.max_bytes, @max_bytes)}) do
      {:ok, built |> Map.take(@output_keys) |> Map.put(:stream, stream)}
    end
  end

  @doc "Fetch the voice catalog only on an explicit call with current credentials."
  def list_voices(request, config) do
    with :ok <- options(request, ~w(api_key base_url timeout_ms deadline_ms)a, :invalid_request),
         {:ok, timeout} <- timeout(request),
         {:ok, _deadline, transport_deadline} <- deadline(timeout, request[:deadline_ms]),
         api_key = trim(request[:api_key]) || trim(config[:api_key]),
         true <- is_binary(api_key),
         base_url = normalize_base(request[:base_url] || config[:base_url]),
         {:ok, bytes} <-
           http(:get, %{
             url: base_url <> "/v1/voices",
             headers: [{"xi-api-key", api_key}],
             body: nil,
             transport_deadline_ms: transport_deadline,
             max_bytes: @max_bytes
           }),
         {:ok, json} <- Jason.decode(bytes) do
      {:ok,
       json
       |> Map.get("voices", [])
       |> Enum.map(fn voice ->
         %{}
         |> optional(:id, trim(voice["voice_id"]))
         |> optional(:name, trim(voice["name"]))
         |> optional(:category, trim(voice["category"]))
         |> optional(:description, trim(voice["description"]))
       end)
       |> Enum.filter(&is_binary(&1[:id]))}
    else
      false -> {:error, :invalid_config}
      error -> error
    end
  end

  defp buffered(built) do
    with {:ok, audio} <- http(:post, built) do
      {:ok, built |> Map.take(@output_keys) |> Map.put(:audio, audio)}
    end
  end

  defp resolve(config, overrides) do
    base_url = normalize_base(config[:base_url])
    voice_id = trim(overrides[:voice_id]) || trim(config[:voice_id]) || @voice_id
    model_id = model(trim(overrides[:model_id]) || trim(config[:model_id]) || @model_id)
    language = trim(overrides[:language_code]) || trim(config[:language_code])

    normalization =
      trim(overrides[:apply_text_normalization]) || trim(config[:apply_text_normalization])

    with true <- is_binary(trim(config[:api_key])),
         true <- Regex.match?(~r/^[a-zA-Z0-9]{10,40}$/, voice_id),
         {:ok, %URI{scheme: scheme, host: host}}
         when scheme in ["http", "https"] and is_binary(host) <- URI.new(base_url),
         {:ok, language} <- language(language),
         {:ok, normalization} <- normalization(normalization) do
      settings =
        @voice_settings
        |> Map.merge(voice_settings(config[:voice_settings]))
        |> Map.merge(voice_settings(overrides[:voice_settings]))

      {:ok,
       %{
         base_url: base_url,
         voice_id: voice_id,
         model_id: model_id,
         seed:
           integer(overrides[:seed], 0, 4_294_967_295) || integer(config[:seed], 0, 4_294_967_295),
         apply_text_normalization: normalization,
         language_code: language,
         voice_settings: settings,
         latency_tier: integer(overrides[:latency_tier], 0, 4)
       }}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid_config}
    end
  end

  defp model("eleven_turbo_v2_5"), do: "eleven_flash_v2_5"
  defp model("eleven_turbo_v2"), do: "eleven_flash_v2"
  defp model(value), do: value

  defp source_voice_settings(raw) do
    raw = record(raw)

    voice_settings(%{
      stability: raw["stability"],
      similarity_boost: raw["similarityBoost"],
      style: raw["style"],
      use_speaker_boost: raw["useSpeakerBoost"],
      speed: raw["speed"]
    })
  end

  defp voice_settings(value) when is_map(value) do
    Enum.reduce(Map.keys(@voice_settings), %{}, fn key, settings ->
      value = Map.get(value, key, Map.get(value, to_string(key)))

      normalized =
        case key do
          :use_speaker_boost when is_boolean(value) -> value
          :speed -> number(value, 0.5, 2)
          key when key in [:stability, :similarity_boost, :style] -> number(value, 0, 1)
          _ -> nil
        end

      optional(settings, key, normalized)
    end)
  end

  defp voice_settings(_), do: %{}
  defp number(value, min, max) when is_number(value) and value >= min and value <= max, do: value
  defp number(_, _, _), do: nil

  defp integer(value, min, max) when is_integer(value) and value >= min and value <= max,
    do: value

  defp integer(value, min, max) when is_float(value) and value >= min and value <= max do
    if value == trunc(value), do: trunc(value)
  end

  defp integer(_, _, _), do: nil

  defp language(nil), do: {:ok, nil}

  defp language(value) do
    value = String.downcase(value)

    if Regex.match?(~r/^[a-z]{2}$/, value),
      do: {:ok, value},
      else: {:error, :invalid_language_code}
  end

  defp normalization(nil), do: {:ok, nil}

  defp normalization(value) do
    value = String.downcase(value)
    if value in ~w(auto on off), do: {:ok, value}, else: {:error, :invalid_text_normalization}
  end

  defp normalized_optional(value, normalize) do
    case normalize.(trim(value)) do
      {:ok, normalized} -> normalized
      {:error, reason} -> raise ArgumentError, Atom.to_string(reason)
    end
  end

  defp output(format) do
    family = format |> String.downcase() |> String.split("_", parts: 2) |> hd()

    %{
      output_format: format,
      file_extension: if(family in @families, do: "." <> family, else: ".bin"),
      voice_compatible: family == "opus"
    }
    |> optional(:media_format, if(family in ~w(mp3 opus wav), do: family))
  end

  defp options(value, keys, error) when is_map(value) and not is_struct(value) do
    if Enum.all?(Map.keys(value), &(&1 in keys)), do: :ok, else: {:error, error}
  end

  defp options(_, _, error), do: {:error, error}

  defp timeout(request) do
    case Map.get(request, :timeout_ms, 30_000) do
      value when is_integer(value) and value > 0 and value <= @max_timeout -> {:ok, value}
      _ -> {:error, :invalid_timeout}
    end
  end

  defp byte_limit(config) do
    case Map.get(config, :max_bytes, @max_bytes) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, :invalid_max_bytes}
    end
  end

  # Preserve the supplied absolute deadline for the effect owner, while every
  # transport wait shares one ceiling clipped to the original operation T.
  defp deadline(timeout, absolute) when is_nil(absolute) or is_integer(absolute) do
    transport = now() + timeout
    deadline = absolute || transport
    transport = min(transport, deadline)
    if remaining(transport) > 0, do: {:ok, deadline, transport}, else: {:error, :timeout}
  end

  defp deadline(_, _), do: {:error, :invalid_deadline}
  defp now, do: System.monotonic_time(:millisecond)
  defp remaining(deadline), do: max(0, deadline - now())
  defp normalize_base(value), do: (trim(value) || @base_url) |> String.trim_trailing("/")
  defp record(value) when is_map(value) and not is_struct(value), do: value
  defp record(_), do: %{}

  defp trim(value) when is_binary(value) do
    case Regex.replace(@js_trim, value, "") do
      "" -> nil
      value -> value
    end
  end

  defp trim(_), do: nil
  defp optional(map, _key, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)

  defp http(method, built) do
    case remaining(built.transport_deadline_ms) do
      0 ->
        {:error, :timeout}

      duration ->
        task = Task.async(fn -> perform(method, built, duration) end)

        case Task.yield(task, remaining(built.transport_deadline_ms)) ||
               Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> completed(task.pid, result, built.transport_deadline_ms)
          nil -> {:error, :timeout}
          {:exit, _reason} -> {:error, :transport}
        end
    end
  end

  defp completed(pid, result, deadline) do
    monitor = Process.monitor(pid)

    try do
      receive do
        {:DOWN, ^monitor, :process, ^pid, _reason} -> result
      after
        remaining(deadline) -> {:error, :timeout}
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp perform(method, built, duration) do
    Req.new(
      method: method,
      url: built.url,
      headers: built.headers,
      body: if(is_nil(built.body), do: nil, else: Jason.encode!(built.body)),
      raw: true,
      compressed: false,
      into: fn event, pair -> collect(event, pair, built) end,
      retry: false,
      redirect: false,
      receive_timeout: duration,
      request_timeout: duration,
      finch: [pool_timeout: duration]
    )
    |> Req.request()
    |> response(built.transport_deadline_ms)
  rescue
    _exception -> {:error, :transport}
  catch
    :exit, _reason -> {:error, :transport}
  end

  defp collect({:data, data}, {request, response}, built) do
    {size, chunks} = Req.Response.get_private(response, :speech_body, {0, []})

    cond do
      remaining(built.transport_deadline_ms) == 0 ->
        {:halt, {request, Req.Response.put_private(response, :speech_timeout, true)}}

      size + byte_size(data) > built.max_bytes ->
        {:halt, {request, Req.Response.put_private(response, :speech_limit, true)}}

      true ->
        {:cont,
         {request,
          Req.Response.put_private(
            response,
            :speech_body,
            {size + byte_size(data), [data | chunks]}
          )}}
    end
  end

  defp response({:ok, response}, deadline) do
    cond do
      remaining(deadline) == 0 or Req.Response.get_private(response, :speech_timeout, false) ->
        {:error, :timeout}

      Req.Response.get_private(response, :speech_limit, false) ->
        {:error, :response_too_large}

      response.status not in 200..299 ->
        {:error, {:http_status, response.status}}

      true ->
        {_size, chunks} = Req.Response.get_private(response, :speech_body, {0, []})
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  defp response({:error, _reason}, _deadline), do: {:error, :transport}
end
