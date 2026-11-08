defmodule Synapsis.Provider.Speech.OpenAI do
  @moduledoc """
  Buffered OpenAI-compatible speech with explicit source configuration phases.

  `resolve_config/1` handles raw source namespaces; synthesis receives resolved
  atom-keyed configuration and preserves its URL trailing slashes. Talk callbacks
  are pure and do not install a consumer. Ordinary and dedicated telephony methods
  share one bounded HTTP transport. Native admission, the original absolute
  deadline, publication and replay remain caller-owned. No ambient credentials
  or source readiness authority is installed.
  """

  @base_url "https://api.openai.com/v1"
  @models ~w(gpt-4o-mini-tts gpt-4o-mini-tts-2025-12-15 tts-1 tts-1-hd)
  @voices ~w(alloy ash ballad cedar coral echo fable juniper marin onyx nova sage shimmer verse)
  @request_keys [:text, :target, :timeout_ms, :deadline_ms, :provider_overrides]
  @config_keys [
    :api_key,
    :base_url,
    :model,
    :voice,
    :speed,
    :instructions,
    :response_format,
    :extra_body,
    :max_bytes
  ]
  @override_keys [:model, :voice, :speed]
  @max_timeout 2_147_483_647
  @max_bytes 16 * 1024 * 1024
  @js_space "[\\x{0009}-\\x{000D}\\x{0020}\\x{00A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}]"
  @js_trim Regex.compile!("\\A#{@js_space}+|#{@js_space}+\\z", "u")

  @type request :: %{
          required(:text) => binary(),
          required(:target) => :audio_file | :voice_note | :telephony,
          optional(:timeout_ms) => number(),
          optional(:deadline_ms) => integer(),
          optional(:provider_overrides) => map()
        }

  def metadata do
    %{
      id: "openai",
      label: "OpenAI",
      auto_select_order: 10,
      default_model: hd(@models),
      models: @models,
      voices: @voices
    }
  end

  def models, do: @models
  def voices, do: @voices
  def list_voices, do: {:ok, Enum.map(@voices, &%{id: &1, name: &1})}

  @doc "Resolve raw string-keyed source namespaces without host API-root preparation."
  def resolve_config(raw_config) do
    raw = record(raw_config)
    nested = record(raw["providers"])["openai"]

    selected =
      cond do
        plain_record?(nested) -> nested
        plain_record?(raw["openai"]) -> raw["openai"]
        true -> raw
      end

    base_url = String.trim_trailing(optional_string(selected["baseUrl"]) || @base_url, "/")

    %{
      base_url: base_url,
      model: optional_string(selected["model"]) || hd(@models),
      voice: optional_string(selected["voice"]) || "coral"
    }
    |> put_optional(:api_key, optional_string(selected["apiKey"]))
    |> put_optional(:speed, speed(selected["speed"], base_url != @base_url))
    |> put_optional(:instructions, optional_string(selected["instructions"]))
    |> put_optional(:response_format, normalized_format(selected["responseFormat"]))
    |> put_optional(:extra_body, source_extra_body(selected))
  end

  def resolve_talk_config(base_tts_config, talk_provider_config) do
    base = resolve_config(base_tts_config)
    talk = record(talk_provider_config)

    base_url = optional_string(talk["baseUrl"]) || base.base_url

    base =
      case Map.fetch(talk, "apiKey") do
        {:ok, value} ->
          base |> Map.delete(:api_key) |> put_optional(:api_key, optional_string(value))

        :error ->
          base
      end

    base
    |> Map.put(:base_url, base_url)
    |> Map.put(:model, optional_string(talk["modelId"]) || base.model)
    |> Map.put(:voice, optional_string(talk["voiceId"]) || base.voice)
    |> put_optional(
      :speed,
      speed(talk["speed"], String.trim_trailing(base_url, "/") != @base_url) || base[:speed]
    )
    |> put_optional(:instructions, optional_string(talk["instructions"]) || base[:instructions])
    |> put_optional(
      :response_format,
      normalized_format(talk["responseFormat"]) || base[:response_format]
    )
  end

  def resolve_talk_overrides(params) do
    params = record(params)

    %{}
    |> put_optional(:model, optional_string(params["modelId"]))
    |> put_optional(:voice, optional_string(params["voiceId"]))
    |> put_optional(:speed, finite_number(params["speed"]))
  end

  @spec build_request(request(), map()) :: {:ok, map()} | {:error, term()}
  def build_request(request, config), do: build(request, config, :ordinary)

  @doc "Build the distinct source phone request with selected PCM at 24 kHz."
  def build_telephony_request(request, config), do: build(request, config, :telephony)

  defp build(request, config, mode) do
    with :ok <- validate_options(request, @request_keys, :invalid_request),
         :ok <- validate_options(config, @config_keys, :invalid_config),
         :ok <- validate_text(request[:text]),
         :ok <- validate_target(request[:target]),
         :ok <- validate_deadline(request[:deadline_ms]),
         {:ok, timeout} <- timeout(request),
         {:ok, limit} <- byte_limit(config),
         {:ok, overrides} <- overrides(request),
         {:ok, resolved} <- resolve(config, overrides),
         {:ok, extra_body} <- extra_body(config[:extra_body]) do
      format = if mode == :telephony, do: "pcm", else: response_format(request.target, resolved)

      body =
        %{
          "model" => resolved.model,
          "input" => request.text,
          "voice" => resolved.voice,
          "response_format" => format
        }
        |> put_optional("speed", resolved.speed)
        |> put_optional("instructions", resolved.instructions)
        |> Map.merge(extra_body)

      {:ok,
       Map.merge(output_metadata(mode, request.target, format), %{
         url: resolved.base_url <> "/audio/speech",
         body: body,
         timeout_ms: timeout,
         max_bytes: limit
       })
       |> put_optional(:deadline_ms, request[:deadline_ms])}
    end
  end

  @spec synthesize(request(), map()) :: {:ok, map()} | {:error, term()}
  def synthesize(request, config) do
    with {:ok, built} <- build_request(request, config), do: synthesize_built(built, config)
  end

  def synthesize_telephony(request, config) do
    with {:ok, built} <- build_telephony_request(request, config),
         do: synthesize_built(built, config)
  end

  defp synthesize_built(built, config) do
    duration = timer(built.timeout_ms)
    deadline = min(now() + duration, built[:deadline_ms] || now() + duration)

    with {:ok, audio} <- http(built, optional_string(config[:api_key]), deadline) do
      output =
        built
        |> Map.take([:output_format, :file_extension, :voice_compatible, :sample_rate])
        |> Map.reject(fn {_key, value} -> is_nil(value) end)

      {:ok, Map.put(output, :audio, audio)}
    end
  end

  defp validate_options(options, keys, error) when is_map(options) do
    if Enum.all?(Map.keys(options), &(&1 in keys)), do: :ok, else: {:error, error}
  end

  defp validate_options(_options, _keys, error), do: {:error, error}

  defp validate_text(text) when is_binary(text) do
    if String.valid?(text), do: :ok, else: {:error, :invalid_text}
  end

  defp validate_text(_text), do: {:error, :invalid_text}

  defp validate_target(target) when target in [:audio_file, :voice_note, :telephony], do: :ok
  defp validate_target(_target), do: {:error, :invalid_target}

  defp timeout(request) do
    case Map.get(request, :timeout_ms, 30_000) do
      value when is_number(value) and value > 0 -> {:ok, value}
      _ -> {:error, :invalid_timeout}
    end
  end

  defp byte_limit(config) do
    case Map.get(config, :max_bytes, @max_bytes) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, :invalid_max_bytes}
    end
  end

  defp overrides(request) do
    value = Map.get(request, :provider_overrides, %{})

    with :ok <- validate_options(value, @override_keys, :invalid_overrides) do
      {:ok, value}
    end
  end

  defp resolve(config, overrides) do
    base_url = optional_string(config[:base_url]) || @base_url
    custom = String.trim_trailing(base_url, "/") != @base_url
    model = optional_string(overrides[:model]) || optional_string(config[:model]) || hd(@models)
    voice = optional_string(overrides[:voice]) || optional_string(config[:voice]) || "coral"
    speed = speed(overrides[:speed], custom) || speed(config[:speed], custom)

    with :ok <- validate_base_url(base_url),
         :ok <- credentials(config[:api_key]),
         :ok <- selection(model, @models, custom, :invalid_model),
         :ok <- selection(voice, @voices, custom, :invalid_voice),
         {:ok, format} <- configured_format(config[:response_format]) do
      instructions =
        if custom or String.contains?(model, "gpt-4o-mini-tts"),
          do: optional_string(config[:instructions])

      {:ok,
       %{
         base_url: base_url,
         model: model,
         voice: voice,
         speed: speed,
         instructions: instructions,
         response_format: format
       }}
    end
  end

  defp validate_base_url(base_url) do
    case URI.new(base_url) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) ->
        :ok

      _ ->
        {:error, :invalid_base_url}
    end
  end

  defp credentials(value) do
    if optional_string(value), do: :ok, else: {:error, :missing_credentials}
  end

  defp selection(_value, _choices, true, _error), do: :ok

  defp selection(value, choices, false, error) do
    if value in choices, do: :ok, else: {:error, error}
  end

  defp speed(value, true) when is_number(value), do: value
  defp speed(value, false) when is_number(value) and value >= 0.25 and value <= 4, do: value
  defp speed(_value, _custom), do: nil

  defp configured_format(value) do
    case optional_string(value) do
      nil -> {:ok, nil}
      format -> validate_format(String.downcase(format))
    end
  end

  defp validate_format(format) when format in ["mp3", "opus", "wav"], do: {:ok, format}
  defp validate_format(_format), do: {:error, :invalid_response_format}

  defp response_format(_target, %{response_format: format}) when is_binary(format), do: format

  defp response_format(target, %{base_url: base_url}) do
    host = base_url |> URI.parse() |> Map.fetch!(:host) |> String.downcase()

    cond do
      host == "groq.com" or String.ends_with?(host, ".groq.com") -> "wav"
      target == :voice_note -> "opus"
      true -> "mp3"
    end
  end

  defp output_metadata(:telephony, _target, "pcm") do
    %{output_format: "pcm", file_extension: nil, voice_compatible: nil, sample_rate: 24_000}
  end

  defp output_metadata(:ordinary, target, format) do
    %{
      output_format: format,
      file_extension: "." <> format,
      voice_compatible: target == :voice_note and format in ["mp3", "opus"],
      sample_rate: nil
    }
  end

  defp optional_string(value) when is_binary(value) do
    if String.valid?(value) do
      case Regex.replace(@js_trim, value, "") do
        "" -> nil
        trimmed -> trimmed
      end
    end
  end

  defp optional_string(_value), do: nil

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp extra_body(nil), do: {:ok, %{}}

  defp extra_body(value) when is_map(value) do
    body =
      Map.new(value, fn {key, entry} -> {to_string(key), entry} end)
      |> Map.drop(["__proto__", "constructor", "prototype"])

    case Jason.encode(body) do
      {:ok, _encoded} -> {:ok, body}
      {:error, _reason} -> {:error, :invalid_extra_body}
    end
  rescue
    _exception -> {:error, :invalid_extra_body}
  end

  defp extra_body(_value), do: {:error, :invalid_extra_body}

  defp validate_deadline(nil), do: :ok
  defp validate_deadline(value) when is_integer(value), do: :ok
  defp validate_deadline(_), do: {:error, :invalid_deadline}

  defp record(value) when is_map(value) and not is_struct(value), do: value
  defp record(_), do: %{}
  defp plain_record?(value), do: is_map(value) and not is_struct(value)
  defp finite_number(value) when is_number(value), do: value
  defp finite_number(_), do: nil

  defp normalized_format(value) do
    case configured_format(value) do
      {:ok, format} -> format
      {:error, _} -> raise ArgumentError, "invalid OpenAI speech response format"
    end
  end

  defp source_extra_body(raw) do
    camel = record(raw["extraBody"])
    snake = record(raw["extra_body"])

    cond do
      map_size(camel) > 0 -> camel
      map_size(snake) > 0 -> snake
      true -> nil
    end
  end

  defp timer(value), do: value |> floor() |> max(1) |> min(@max_timeout)
  defp now, do: System.monotonic_time(:millisecond)
  defp remaining(deadline), do: max(deadline - now(), 0)

  defp http(built, api_key, deadline) do
    case remaining(deadline) do
      0 ->
        {:error, :timeout}

      duration ->
        # The one linked task owns Req/Finch collection and is joined or stopped
        # within the original deadline, including pool checkout and body reads.
        task = Task.async(fn -> perform(built, api_key, deadline, duration) end)

        case Task.yield(task, remaining(deadline)) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> completed(task.pid, result, deadline)
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

  defp perform(built, api_key, deadline, duration) do
    Req.new(
      method: :post,
      url: built.url,
      headers: [{"authorization", "Bearer " <> api_key}, {"content-type", "application/json"}],
      body: Jason.encode!(built.body),
      raw: true,
      compressed: false,
      into: fn event, pair -> collect(event, pair, built.max_bytes, deadline) end,
      retry: false,
      redirect: false,
      receive_timeout: duration,
      request_timeout: duration,
      finch: [pool_timeout: duration]
    )
    |> Req.request()
    |> response(deadline)
  rescue
    _exception -> {:error, :transport}
  catch
    :exit, _reason -> {:error, :transport}
  end

  defp collect({:data, data}, {request, response}, limit, deadline) do
    {size, chunks} = Req.Response.get_private(response, :speech_body, {0, []})

    cond do
      remaining(deadline) == 0 ->
        {:halt, {request, Req.Response.put_private(response, :speech_timeout, true)}}

      size + byte_size(data) > limit ->
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
