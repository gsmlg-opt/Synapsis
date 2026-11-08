defmodule Synapsis.Provider.Speech.ClawRouter do
  @moduledoc """
  Buffered ClawRouter speech using explicit current host credentials.

  Source configuration and Talk callbacks are pure. Native effect admission,
  the original absolute deadline, publication and replay remain caller-owned.
  No profile store, ambient credentials or readiness authority is installed.
  """

  @model "openai/tts-1"
  @voices ~w(alloy echo fable onyx nova shimmer)
  @formats ~w(mp3 opus aac flac wav pcm)
  @base_url "https://clawrouter.openclaw.ai"
  @max_bytes 16 * 1024 * 1024
  @max_timeout 2_147_000_000
  @js_space "[\\x{0009}-\\x{000D}\\x{0020}\\x{00A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}]"
  @js_trim Regex.compile!("\\A#{@js_space}+|#{@js_space}+\\z", "u")

  def metadata do
    %{
      id: "clawrouter",
      label: "ClawRouter",
      default_model: @model,
      models: [@model],
      voices: @voices
    }
  end

  def models, do: [@model]
  def voices, do: @voices
  def list_voices, do: {:ok, Enum.map(@voices, &%{id: &1, name: &1})}

  def resolve_config(raw_config) do
    providers = record(record(raw_config)["providers"])
    normalize(record(providers["clawrouter"]))
  end

  def resolve_talk_config(base_tts_config, talk_provider_config) do
    base = resolve_config(base_tts_config)
    talk = record(talk_provider_config)

    base
    |> Map.new(fn {key, value} -> {source_key(key), value} end)
    |> Map.merge(talk)
    |> Map.put("model", coalesce(talk["modelId"], base.model))
    |> Map.put("voice", configured_voice(talk) || base.voice)
    |> normalize()
  end

  # Pure callbacks retain profile provenance; actual requests reject explicit
  # profiles because this host has no source credential/profile store.
  # Return literal values and preserve explicit nil independently of absence.
  def resolve_talk_overrides(params) do
    params = record(params)

    Enum.reduce([{"modelId", :model}, {"voiceId", :voice}, {"speed", :speed}], %{}, fn
      {source, host}, acc ->
        case Map.fetch(params, source) do
          {:ok, value} -> Map.put(acc, host, value)
          :error -> acc
        end
    end)
  end

  @doc "Build one source-shaped request while preserving raw request duration and text."
  def build_request(request, raw_config) when is_map(request) and is_map(raw_config) do
    config = normalize(raw_config)
    overrides = record(request[:provider_overrides])

    model =
      trim(coalesce(field(overrides, :model, "model"), field(overrides, :model_id, "modelId"))) ||
        config.model

    voice = configured_voice(overrides) || config.voice
    speed = coalesce(field(overrides, :speed, "speed"), config[:speed])

    format =
      config[:response_format] || if(request[:target] == :voice_note, do: "opus", else: "mp3")

    key = trim(field(raw_config, :api_key, "apiKey"))
    limit = field(raw_config, :max_bytes, "max_bytes") || @max_bytes
    timeout = request[:timeout_ms]
    base = config[:base_url] || configured_base(request[:cfg]) || @base_url

    with :ok <- supported_profile(config, overrides, request),
         true <- is_binary(request[:text]) and String.valid?(request.text),
         true <-
           not is_nil(trim(request.text)) and length(String.codepoints(request.text)) <= 4096,
         true <- request[:target] in [:audio_file, :voice_note],
         true <- model == @model and voice in @voices,
         true <-
           (is_nil(speed) and not Map.has_key?(config, :speed)) or
             (is_number(speed) and speed >= 0.25 and speed <= 4),
         true <- is_binary(key),
         true <- is_number(timeout) and timeout > 0,
         true <- is_integer(limit) and limit > 0,
         true <- is_nil(request[:deadline_ms]) or is_integer(request[:deadline_ms]),
         {:ok, %URI{scheme: scheme, host: host}}
         when scheme in ["http", "https"] and is_binary(host) and host != "" <- URI.new(base) do
      {:ok,
       %{
         method: :post,
         url: versioned_base(base) <> "/audio/speech",
         headers: [
           {"authorization", "Bearer " <> key},
           {"content-type", "application/json"},
           {"x-clawrouter-client", "openclaw"}
         ],
         body:
           %{
             "model" => model,
             "input" => request.text,
             "voice" => voice,
             "response_format" => format
           }
           |> optional("speed", speed),
         timeout_ms: timeout,
         max_bytes: limit,
         output_format: format,
         file_extension: "." <> format,
         voice_compatible: format == "opus"
       }
       |> optional(:deadline_ms, request[:deadline_ms])}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_request}
    end
  rescue
    _error in ArgumentError -> {:error, :invalid_config}
  end

  def build_request(_, _), do: {:error, :invalid_request}

  def synthesize(request, config) do
    with {:ok, built} <- build_request(request, config) do
      duration = timer(built.timeout_ms)
      deadline = min(now() + duration, built[:deadline_ms] || now() + duration)

      with {:ok, audio} <- http(built, deadline) do
        {:ok,
         built
         |> Map.take([:output_format, :file_extension, :voice_compatible])
         |> Map.put(:audio, audio)}
      end
    end
  end

  def synthesize_telephony(request, config) do
    config =
      config
      |> Map.delete("responseFormat")
      |> Map.delete("response_format")
      |> Map.put(:response_format, "pcm")

    with {:ok, result} <- synthesize(request, config),
         do: {:ok, Map.put(result, :sample_rate, 24_000)}
  end

  defp normalize(raw) do
    %{
      model:
        trim(coalesce(field(raw, :model, "model"), field(raw, :model_id, "modelId"))) || @model,
      voice: configured_voice(raw) || hd(@voices)
    }
    |> optional(:api_key, trim(field(raw, :api_key, "apiKey")))
    |> optional(:base_url, trim(field(raw, :base_url, "baseUrl")))
    |> optional(:profile_id, trim(field(raw, :profile_id, "profileId")))
    |> then(fn config ->
      if Map.has_key?(raw, "speed") or Map.has_key?(raw, :speed),
        do: Map.put(config, :speed, field(raw, :speed, "speed")),
        else: config
    end)
    |> optional(:response_format, format(field(raw, :response_format, "responseFormat")))
  end

  defp configured_voice(raw) do
    Enum.find_value(
      [
        field(raw, :speaker_voice, "speakerVoice"),
        field(raw, :speaker_voice_id, "speakerVoiceId"),
        field(raw, :voice, "voice"),
        field(raw, :voice_id, "voiceId")
      ],
      &trim/1
    )
  end

  defp format(value) do
    case trim(value) do
      nil ->
        nil

      value ->
        normalized = String.downcase(value)

        if normalized in @formats,
          do: normalized,
          else: raise(ArgumentError, "invalid ClawRouter speech response format")
    end
  end

  defp configured_base(cfg) do
    cfg
    |> record()
    |> Map.get("models")
    |> record()
    |> Map.get("providers")
    |> record()
    |> Map.get("clawrouter")
    |> record()
    |> Map.get("baseUrl")
    |> trim()
  end

  defp supported_profile(config, overrides, request) do
    if Map.has_key?(config, :profile_id) or
         not is_nil(trim(field(overrides, :profile_id, "profileId"))) or
         not is_nil(trim(field(request, :profile_id, "profileId"))),
       do: {:error, :unsupported_profile},
       else: :ok
  end

  defp versioned_base(base) do
    base = String.trim_trailing(base, "/")

    base =
      if String.ends_with?(base, "/v1"), do: binary_part(base, 0, byte_size(base) - 3), else: base

    base <> "/v1"
  end

  defp source_key(:api_key), do: "apiKey"
  defp source_key(:profile_id), do: "profileId"
  defp source_key(:base_url), do: "baseUrl"
  defp source_key(:response_format), do: "responseFormat"
  defp source_key(key), do: Atom.to_string(key)
  defp coalesce(nil, fallback), do: fallback
  defp coalesce(value, _fallback), do: value

  defp field(raw, host, source),
    do: Map.get(raw, source, Map.get(raw, Atom.to_string(host), Map.get(raw, host)))

  defp optional(map, _, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)
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
  defp timer(value), do: value |> floor() |> max(1) |> min(@max_timeout)
  defp now, do: System.monotonic_time(:millisecond)
  defp remaining(deadline), do: max(deadline - now(), 0)

  defp http(built, deadline) do
    case remaining(deadline) do
      0 ->
        {:error, :timeout}

      duration ->
        task = Task.async(fn -> perform(built, deadline, duration) end)

        case Task.yield(task, remaining(deadline)) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> completed(task.pid, result, deadline)
          nil -> {:error, :timeout}
          {:exit, _} -> {:error, :transport}
        end
    end
  end

  defp completed(pid, result, deadline) do
    monitor = Process.monitor(pid)

    try do
      receive do
        {:DOWN, ^monitor, :process, ^pid, _} -> result
      after
        remaining(deadline) -> {:error, :timeout}
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp perform(built, deadline, duration) do
    Req.new(
      method: :post,
      url: built.url,
      headers: built.headers,
      body: Jason.encode!(built.body),
      raw: true,
      compressed: false,
      retry: false,
      redirect: false,
      request_timeout: duration,
      receive_timeout: duration,
      finch: [pool_timeout: duration],
      into: fn event, pair -> collect(event, pair, built.max_bytes, deadline) end
    )
    |> Req.request()
    |> response(deadline)
  rescue
    _ -> {:error, :transport}
  catch
    :exit, _ -> {:error, :transport}
  end

  defp collect({:data, data}, {request, response}, limit, deadline) do
    {size, chunks} = Req.Response.get_private(response, :clawrouter_body, {0, []})

    cond do
      remaining(deadline) == 0 ->
        {:halt, {request, Req.Response.put_private(response, :clawrouter_timeout, true)}}

      size + byte_size(data) > limit ->
        {:halt, {request, Req.Response.put_private(response, :clawrouter_limit, true)}}

      true ->
        {:cont,
         {request,
          Req.Response.put_private(
            response,
            :clawrouter_body,
            {size + byte_size(data), [data | chunks]}
          )}}
    end
  end

  defp response({:ok, response}, deadline) do
    cond do
      remaining(deadline) == 0 or Req.Response.get_private(response, :clawrouter_timeout, false) ->
        {:error, :timeout}

      Req.Response.get_private(response, :clawrouter_limit, false) ->
        {:error, :response_too_large}

      response.status not in 200..299 ->
        {:error, {:http_status, response.status}}

      true ->
        {_, chunks} = Req.Response.get_private(response, :clawrouter_body, {0, []})
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  defp response({:error, _}, _), do: {:error, :transport}
end
