defmodule Synapsis.Provider.Speech.OpenRouter do
  @moduledoc """
  Explicitly configured OpenRouter speech with opaque MP3 or PCM output.

  Source config callbacks accept string-key OpenClaw shapes and return atom-key
  maps. They preserve absent optional fields and nested provider routing without
  interning routing keys. Synthesis accepts the normalized map plus `:max_bytes`;
  request maps contain `:text`, `:target` (`:audio_file` or `:voice_note`), optional
  `:timeout_ms` and `:provider_overrides`. Overrides accept `:model`/`:model_id`,
  `:voice`/`:voice_id` and `:speed`, with source nullish precedence before trimming.

  Credentials come from the caller's selected Providers runtime, never environment
  lookup. HTTP runs in a linked task with the full finite synthesis allowance for
  request, receive and pool waits. Native effect admission/deadlines and immutable
  media publication remain host responsibilities. PCM has no inferred sample rate,
  channels, codec or playback contract.
  """

  @base_url "https://openrouter.ai/api/v1"
  @model "hexgrad/kokoro-82m"
  @voice "af_alloy"
  @models [
    @model,
    "elevenlabs/eleven-turbo-v2",
    "google/gemini-3.1-flash-tts-preview",
    "mistralai/voxtral-mini-tts-2603"
  ]
  @timeout 120_000
  @max_timeout 2_147_483_647
  @max_bytes 16 * 1024 * 1024
  @request_keys [:text, :target, :timeout_ms, :provider_overrides]
  @config_keys [
    :api_key,
    :base_url,
    :model,
    :voice,
    :speed,
    :response_format,
    :provider,
    :max_bytes
  ]
  @override_keys [:model, :model_id, :voice, :voice_id, :speed]
  @js_space "[\\x{0009}-\\x{000D}\\x{0020}\\x{00A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}]"
  @js_trim Regex.compile!("\\A#{@js_space}+|#{@js_space}+\\z", "u")

  def models, do: @models
  def voices, do: [%{id: @voice, name: @voice}]
  def default_timeout_ms, do: @timeout

  @doc "Normalize a source TTS root, preferring providers.openrouter over legacy openrouter."
  def resolve_config(raw_config) do
    root = record(raw_config) || %{}
    providers = record(root["providers"]) || %{}
    raw = record(providers["openrouter"]) || record(root["openrouter"]) || %{}

    %{
      model: trim(coalesce(raw["model"], raw["modelId"])) || @model,
      voice: configured_voice(raw) || @voice
    }
    |> put_optional(:api_key, trim(raw["apiKey"]))
    |> put_optional(:base_url, optional_base_url(raw["baseUrl"]))
    |> put_optional(:speed, number(raw["speed"]))
    |> put_optional(:response_format, source_format(raw["responseFormat"]))
    |> put_optional(:provider, record(raw["provider"]))
  end

  @doc "Overlay source Talk connection/voice settings while retaining base provider routing."
  def resolve_talk_config(base_tts_config, talk_provider_config) do
    talk = record(talk_provider_config) || %{}
    base = resolve_config(base_tts_config)

    base =
      if Map.has_key?(talk, "apiKey") do
        base |> Map.delete(:api_key) |> put_optional(:api_key, trim(talk["apiKey"]))
      else
        base
      end

    base
    |> put_optional(:base_url, optional_base_url(talk["baseUrl"]))
    |> put_optional(:model, trim(talk["modelId"]))
    |> put_optional(:voice, configured_voice(talk))
    |> put_optional(:speed, number(talk["speed"]))
    |> put_optional(:response_format, source_format(talk["responseFormat"]))
  end

  @doc "Normalize Talk ID-first overrides; a selected blank ID does not fall through to its alias."
  def resolve_talk_overrides(params) do
    params = record(params) || %{}

    %{}
    |> put_optional(:voice, trim(coalesce(params["voiceId"], params["voice"])))
    |> put_optional(:model, trim(coalesce(params["modelId"], params["model"])))
    |> put_optional(:speed, number(params["speed"]))
  end

  @spec build_request(map(), map()) :: {:ok, map()} | {:error, term()}
  def build_request(request, config) do
    with :ok <- options(request, @request_keys, :invalid_request),
         :ok <- options(config, @config_keys, :invalid_config),
         true <- is_binary(request[:text]) and String.valid?(request.text),
         true <- request[:target] in [:audio_file, :voice_note],
         {:ok, timeout} <- timeout(request),
         {:ok, limit} <- byte_limit(config),
         overrides = Map.get(request, :provider_overrides, %{}),
         :ok <- options(overrides, @override_keys, :invalid_overrides),
         {:ok, base_url} <- base_url(config),
         {:ok, format} <- configured_format(config[:response_format]),
         {:ok, routing} <- routing(config[:provider]) do
      body =
        %{
          "model" =>
            trim(coalesce(overrides[:model], overrides[:model_id])) || trim(config[:model]) ||
              @model,
          "input" => request.text,
          "voice" =>
            trim(coalesce(overrides[:voice], overrides[:voice_id])) || trim(config[:voice]) ||
              @voice,
          "response_format" => format
        }
        |> put_optional("speed", number(overrides[:speed]) || number(config[:speed]))
        |> put_optional("provider", routing)

      {:ok,
       %{
         url: base_url <> "/audio/speech",
         body: body,
         timeout_ms: timeout,
         max_bytes: limit,
         output_format: format,
         file_extension: "." <> format,
         voice_compatible: format == "mp3"
       }}
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  @spec synthesize(map(), map()) :: {:ok, map()} | {:error, term()}
  def synthesize(request, config) do
    with {:ok, built} <- build_request(request, config) do
      task = Task.async(fn -> perform(built, trim(config[:api_key])) end)

      case Task.yield(task, built.timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, audio}} ->
          {:ok,
           built
           |> Map.take([:output_format, :file_extension, :voice_compatible])
           |> Map.put(:audio, audio)}

        {:ok, {:error, reason}} ->
          {:error, reason}

        nil ->
          {:error, :timeout}

        {:exit, _reason} ->
          {:error, :transport}
      end
    end
  end

  defp configured_voice(raw) do
    Enum.find_value(~w(speakerVoice speakerVoiceId voice voiceId), &trim(raw[&1]))
  end

  defp optional_base_url(value) do
    if value = trim(value), do: normalize_base_url(value)
  end

  defp normalize_base_url(value) do
    case String.trim_trailing(value, "/") do
      "https://openrouter.ai/v1" -> @base_url
      url -> url
    end
  end

  defp base_url(config) do
    url = normalize_base_url(trim(config[:base_url]) || @base_url)

    with true <- is_binary(trim(config[:api_key])),
         {:ok, %URI{scheme: scheme, host: host}}
         when scheme in ["http", "https"] and is_binary(host) and host != "" <- URI.new(url) do
      {:ok, url}
    else
      _ -> {:error, :invalid_config}
    end
  end

  defp configured_format(value) do
    case trim(value) do
      nil ->
        {:ok, "mp3"}

      format ->
        case String.downcase(format) do
          format when format in ["mp3", "pcm"] -> {:ok, format}
          _ -> {:error, :invalid_response_format}
        end
    end
  end

  defp source_format(value) do
    if trim(value) do
      case configured_format(value) do
        {:ok, format} -> format
        {:error, _} -> raise ArgumentError, "invalid OpenRouter speech response format"
      end
    end
  end

  defp timeout(request) do
    case Map.get(request, :timeout_ms, @timeout) do
      value when is_integer(value) and value > 0 -> {:ok, min(value, @max_timeout)}
      _ -> {:error, :invalid_timeout}
    end
  end

  defp byte_limit(config) do
    case Map.get(config, :max_bytes, @max_bytes) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, :invalid_max_bytes}
    end
  end

  defp routing(nil), do: {:ok, nil}

  defp routing(value) when is_map(value) and not is_struct(value) do
    case Jason.encode(value) do
      {:ok, _} -> {:ok, value}
      _ -> {:error, :invalid_provider_routing}
    end
  end

  defp routing(_), do: {:error, :invalid_provider_routing}

  defp options(value, keys, error) when is_map(value) and not is_struct(value) do
    if Enum.all?(Map.keys(value), &(&1 in keys)), do: :ok, else: {:error, error}
  end

  defp options(_, _, error), do: {:error, error}

  defp record(value) when is_map(value) and not is_struct(value), do: value
  defp record(_), do: nil
  defp coalesce(nil, fallback), do: fallback
  defp coalesce(value, _fallback), do: value
  defp number(value) when is_number(value), do: value
  defp number(_), do: nil

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

  defp perform(built, api_key) do
    Req.Request.new()
    |> Req.Steps.attach()
    |> Req.merge(
      method: :post,
      url: built.url,
      headers: [{"authorization", "Bearer " <> api_key}, {"content-type", "application/json"}],
      body: Jason.encode!(built.body),
      raw: true,
      compressed: false,
      into: fn event, pair -> collect(event, pair, built.max_bytes) end,
      retry: false,
      redirect: false,
      receive_timeout: built.timeout_ms,
      request_timeout: built.timeout_ms,
      finch: [pool_timeout: built.timeout_ms]
    )
    |> Req.request()
    |> response()
  rescue
    _exception -> {:error, :transport}
  catch
    :exit, _reason -> {:error, :transport}
  end

  defp collect({:data, data}, {request, response}, limit) do
    {size, chunks} = Req.Response.get_private(response, :speech_body, {0, []})

    if size + byte_size(data) <= limit do
      {:cont,
       {request,
        Req.Response.put_private(
          response,
          :speech_body,
          {size + byte_size(data), [data | chunks]}
        )}}
    else
      {:halt, {request, Req.Response.put_private(response, :speech_limit, true)}}
    end
  end

  defp response({:ok, response}) do
    cond do
      Req.Response.get_private(response, :speech_limit, false) ->
        {:error, :response_too_large}

      response.status not in 200..299 ->
        {:error, {:http_status, response.status}}

      true ->
        {_size, chunks} = Req.Response.get_private(response, :speech_body, {0, []})
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  defp response({:error, _reason}), do: {:error, :transport}
end
