defmodule Synapsis.Provider.Speech.Azure do
  @moduledoc """
  Explicit Azure Speech REST synthesis and voice discovery.

  Credentials and routes are supplied by the caller. This service preserves
  source SSML and opaque audio; native effects, publication and replay belong
  to the host. Talk, directives and telephony are explicit service interfaces.
  """
  @default_format "audio-24khz-48kbitrate-mono-mp3"
  @note_format "ogg-24khz-16bit-mono-opus"
  @phone_format "raw-8khz-8bit-mono-mulaw"
  @max_bytes 16 * 1024 * 1024
  @max_timeout 2_147_483_647
  @js_space "[\\x{0009}-\\x{000D}\\x{0020}\\x{00A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}]"
  @js_trim Regex.compile!("\\A#{@js_space}+|#{@js_space}+\\z", "u")

  def metadata,
    do: %{id: "azure-speech", label: "Azure Speech", aliases: ["azure"], auto_select_order: 30}

  def resolve_config(raw_config) do
    providers = record(record(raw_config)["providers"])

    raw =
      if is_map(providers["azure-speech"]),
        do: providers["azure-speech"],
        else: providers["azure"]

    normalize(record(raw))
  end

  def resolve_talk_config(base_tts_config, talk_provider_config) do
    base = resolve_config(base_tts_config)
    talk = record(talk_provider_config)
    region = trim(talk["region"])
    endpoint = trim(coalesce(talk["endpoint"], talk["baseUrl"]))
    inherited = if is_nil(region) and is_nil(endpoint), do: base[:base_url]
    route = base_url(trim(talk["baseUrl"]) || inherited, endpoint, region || base[:region])

    base
    |> optional(:api_key, trim(talk["apiKey"]))
    |> optional(:region, region)
    |> optional(:endpoint, endpoint)
    |> optional(:base_url, route)
    |> Map.merge(resolve_talk_overrides(talk))
  end

  def resolve_talk_overrides(params) do
    raw = record(params)

    %{}
    |> optional(:voice, trim(raw["voiceId"]))
    |> optional(:lang, trim(raw["languageCode"]))
    |> optional(:output_format, trim(raw["outputFormat"]))
  end

  @doc "Pure directive interface; the consumer owns policy and dispatch."
  def parse_directive_token(context) do
    key = context[:key] || context["key"]
    policy = record(context[:policy] || context["policy"])

    rule =
      cond do
        key in ~w(voice voiceid voice_id azure_voice azurevoice azure_speech_voice) ->
          {:voice, :allowVoice}

        key in ~w(lang language language_code languagecode azure_lang azure_language) ->
          {:lang, :allowVoiceSettings}

        key in ~w(output_format outputformat azure_format azure_output_format) ->
          {:output_format, :allowVoiceSettings}

        true ->
          nil
      end

    case rule do
      nil ->
        %{handled: false}

      {field, flag} ->
        if Map.get(policy, flag, Map.get(policy, Atom.to_string(flag), false)),
          do: %{handled: true, overrides: %{field => Map.get(context, :value, context["value"])}},
          else: %{handled: true}
    end
  end

  @doc "Build exact SSML and preserve the source numeric timeout without HTTP."
  def build_request(request, config) do
    build(request, config, nil)
  end

  defp build(request, config, forced_format) when is_map(request) and is_map(config) do
    config = normalize(config)
    overrides = record(request[:provider_overrides])

    voice =
      trim(coalesce(field(overrides, :voice, "voice"), field(overrides, :voice_id, "voiceId"))) ||
        config.voice

    lang =
      trim(
        coalesce(
          field(overrides, :lang, "lang"),
          field(overrides, :language_code, "languageCode")
        )
      ) || config.lang

    format =
      forced_format || trim(field(overrides, :output_format, "outputFormat")) ||
        if(request[:target] == :voice_note,
          do: config.voice_note_output_format,
          else: config.output_format
        )

    timeout = coalesce(config[:timeout_ms], coalesce(request[:timeout_ms], 30_000))
    limit = config[:max_bytes] || @max_bytes

    with true <- is_binary(request[:text]) and String.valid?(request.text),
         true <- request[:target] in [:audio_file, :voice_note, :telephony],
         true <- is_binary(config[:api_key]) and is_binary(config[:base_url]),
         true <- is_number(timeout) and timeout > 0 and timeout <= @max_timeout,
         true <- is_integer(limit) and limit > 0,
         true <- is_nil(request[:deadline_ms]) or is_integer(request[:deadline_ms]) do
      {:ok,
       output(format)
       |> Map.merge(%{
         method: :post,
         url: config.base_url <> "/cognitiveservices/v1",
         headers: [
           {"content-type", "application/ssml+xml"},
           {"ocp-apim-subscription-key", config.api_key},
           {"x-microsoft-outputformat", format},
           {"user-agent", "Synapsis"}
         ],
         body:
           ~s(<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang=") <>
             escape_attr(lang) <>
             ~s("><voice name=") <>
             escape_attr(voice) <>
             ~s(">) <>
             escape_text(request.text) <> "</voice></speak>",
         timeout_ms: timeout,
         max_bytes: limit
       })
       |> optional(:deadline_ms, request[:deadline_ms])}
    else
      _ -> {:error, :invalid_config}
    end
  end

  defp build(_, _, _), do: {:error, :invalid_request}

  def synthesize(request, config) do
    with {:ok, built} <- build_request(request, config),
         {:ok, audio} <- http(built) do
      {:ok,
       built
       |> Map.take([:output_format, :file_extension, :voice_compatible, :media_format])
       |> Map.put(:audio, audio)}
    end
  end

  def synthesize_telephony(request, config) do
    with {:ok, built} <- build(Map.put(request, :target, :telephony), config, @phone_format),
         {:ok, audio} <- http(built) do
      {:ok, %{audio: audio, output_format: @phone_format, sample_rate: 8_000}}
    end
  end

  def list_voices(request, config) when is_map(request) and is_map(config) do
    config = normalize(config)

    route =
      base_url(
        coalesce(request[:base_url], config[:base_url]),
        config[:endpoint],
        config[:region]
      )

    key = trim(request[:api_key]) || config[:api_key]
    timeout = coalesce(config[:timeout_ms], coalesce(request[:timeout_ms], 30_000))
    limit = config[:max_bytes] || @max_bytes

    with true <- is_binary(route) and is_binary(key),
         true <- is_integer(limit) and limit > 0,
         true <- is_nil(request[:deadline_ms]) or is_integer(request[:deadline_ms]),
         true <- is_number(timeout) and timeout > 0 and timeout <= @max_timeout,
         {:ok, bytes} <-
           http(%{
             method: :get,
             url: route <> "/cognitiveservices/voices/list",
             headers: [{"ocp-apim-subscription-key", key}],
             timeout_ms: timeout,
             max_bytes: limit,
             deadline_ms: request[:deadline_ms]
           }),
         {:ok, voices} <- Jason.decode(bytes) do
      {:ok, if(is_list(voices), do: Enum.flat_map(voices, &voice/1), else: [])}
    else
      false -> {:error, :invalid_config}
      error -> error
    end
  end

  def list_voices(_, _), do: {:error, :invalid_request}

  defp normalize(raw) do
    region = trim(field(raw, :region, "region"))
    endpoint = trim(field(raw, :endpoint, "endpoint"))

    %{
      voice:
        trim(coalesce(field(raw, :voice, "voice"), field(raw, :voice_id, "voiceId"))) ||
          "en-US-JennyNeural",
      lang:
        trim(coalesce(field(raw, :lang, "lang"), field(raw, :language_code, "languageCode"))) ||
          "en-US",
      output_format: trim(field(raw, :output_format, "outputFormat")) || @default_format,
      voice_note_output_format:
        trim(field(raw, :voice_note_output_format, "voiceNoteOutputFormat")) || @note_format
    }
    |> optional(:api_key, trim(field(raw, :api_key, "apiKey")))
    |> optional(:region, region)
    |> optional(:endpoint, endpoint)
    |> optional(:base_url, base_url(field(raw, :base_url, "baseUrl"), endpoint, region))
    |> optional(:timeout_ms, finite(field(raw, :timeout_ms, "timeoutMs")))
    |> optional(:max_bytes, raw[:max_bytes])
  end

  defp base_url(base, endpoint, region) do
    case trim(base) || trim(endpoint) do
      nil ->
        if trim(region), do: "https://#{trim(region)}.tts.speech.microsoft.com"

      configured ->
        configured
        |> String.trim_trailing("/")
        |> then(&Regex.replace(~r/\/cognitiveservices\/v1$/i, &1, ""))
    end
  end

  defp output(format) do
    normalized = String.downcase(format)

    extension =
      cond do
        String.contains?(normalized, "mp3") -> ".mp3"
        String.starts_with?(normalized, "ogg-") -> ".ogg"
        String.starts_with?(normalized, "webm-") -> ".webm"
        String.starts_with?(normalized, "riff-") -> ".wav"
        String.starts_with?(normalized, "raw-") -> ".pcm"
        String.starts_with?(normalized, "amr-") -> ".amr"
        true -> ".audio"
      end

    %{
      output_format: format,
      file_extension: extension,
      media_format: String.trim_leading(extension, "."),
      voice_compatible:
        String.starts_with?(normalized, "ogg-") and String.contains?(normalized, "opus")
    }
  end

  defp voice(raw) when is_map(raw) do
    id = trim(raw["ShortName"])
    status = trim(raw["Status"])
    deprecated = raw["IsDeprecated"]

    if is_nil(id) or deprecated == true or
         (is_binary(deprecated) and String.downcase(deprecated) == "true") or
         (status && String.downcase(status) in ~w(deprecated retired disabled)) do
      []
    else
      tags = record(raw["VoiceTag"])
      scenarios = tags(tags["TailoredScenarios"])
      personalities = tags(tags["VoicePersonalities"])
      description = (scenarios || []) ++ (personalities || [])

      [
        %{id: id}
        |> optional(:name, trim(raw["DisplayName"]) || trim(raw["LocalName"]))
        |> optional(:description, if(description != [], do: Enum.join(description, ", ")))
        |> optional(:locale, trim(raw["Locale"]))
        |> optional(:gender, trim(raw["Gender"]))
        |> optional(:personalities, personalities)
      ]
    end
  end

  defp voice(_), do: []
  defp tags(values) when is_list(values), do: Enum.filter(values, &(not is_nil(trim(&1))))
  defp tags(_), do: nil

  defp http(built) do
    deadline = now() + ceil(built.timeout_ms)
    deadline = min(deadline, built[:deadline_ms] || deadline)

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
    options = [
      method: built.method,
      url: built.url,
      headers: built.headers,
      raw: true,
      compressed: false,
      retry: false,
      redirect: false,
      request_timeout: duration,
      receive_timeout: min(duration, 30_000),
      finch: [pool_timeout: duration],
      into: fn event, pair -> collect(event, pair, built.max_bytes, deadline) end
    ]

    options = if built.method == :post, do: Keyword.put(options, :body, built.body), else: options
    Req.new(options) |> Req.request() |> response(deadline)
  rescue
    _ -> {:error, :transport}
  catch
    :exit, _ -> {:error, :transport}
  end

  defp collect({:data, data}, {request, response}, limit, deadline) do
    {size, chunks} = Req.Response.get_private(response, :azure_body, {0, []})

    cond do
      remaining(deadline) == 0 ->
        {:halt, {request, Req.Response.put_private(response, :azure_timeout, true)}}

      size + byte_size(data) > limit ->
        {:halt, {request, Req.Response.put_private(response, :azure_limit, true)}}

      true ->
        {:cont,
         {request,
          Req.Response.put_private(
            response,
            :azure_body,
            {size + byte_size(data), [data | chunks]}
          )}}
    end
  end

  defp response({:ok, response}, deadline) do
    cond do
      remaining(deadline) == 0 or Req.Response.get_private(response, :azure_timeout, false) ->
        {:error, :timeout}

      Req.Response.get_private(response, :azure_limit, false) ->
        {:error, :response_too_large}

      response.status not in 200..299 ->
        {:error, {:http_status, response.status}}

      true ->
        {_, chunks} = Req.Response.get_private(response, :azure_body, {0, []})
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  defp response({:error, _}, _), do: {:error, :transport}
  defp now, do: System.monotonic_time(:millisecond)
  defp remaining(deadline), do: max(deadline - now(), 0)

  defp escape_text(value),
    do:
      value
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")

  defp escape_attr(value),
    do: value |> escape_text() |> String.replace("\"", "&quot;") |> String.replace("'", "&apos;")

  defp finite(value) when is_number(value), do: value
  defp finite(_), do: nil
  defp field(raw, key, source), do: coalesce(Map.get(raw, key), Map.get(raw, source))
  defp coalesce(nil, other), do: other
  defp coalesce(value, _), do: value
  defp optional(map, _, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)
  defp record(value) when is_map(value) and not is_struct(value), do: value
  defp record(_), do: %{}

  defp trim(value) when is_binary(value) do
    case Regex.replace(@js_trim, value, "") do
      "" -> nil
      value -> value
    end
  end

  defp trim(_), do: nil
end
