defmodule Synapsis.Provider.Speech.Xiaomi do
  @moduledoc """
  Buffered Xiaomi MiMo speech synthesis with explicit saved configuration.

  The service preserves source model, voice, style and audio conventions. Native
  effect admission, publication and completed replay belong to the caller.
  Explicit voice-note synthesis shares the provider-owned FFmpeg Port converter.
  """

  alias Synapsis.Provider.Speech.Opus

  @models ~w(mimo-v2.5-tts mimo-v2.5-tts-voicedesign)
  @voices ~w(mimo_default default_zh default_en Mia Chloe Milo Dean)
  @design_model "mimo-v2.5-tts-voicedesign"
  @design_style "Warm, natural, and friendly voice with clear pronunciation and conversational pacing."
  @base_url "https://api.xiaomimimo.com/v1"
  @max_timeout 2_147_000_000
  @max_bytes 16 * 1024 * 1024
  @js_space "[\\x{0009}-\\x{000D}\\x{0020}\\x{00A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}]"
  @js_trim Regex.compile!("\\A#{@js_space}+|#{@js_space}+\\z", "u")

  def metadata do
    %{
      id: "xiaomi",
      label: "Xiaomi MiMo",
      aliases: ["mimo"],
      auto_select_order: 45,
      default_model: "mimo-v2.5-tts",
      models: @models,
      voices: @voices
    }
  end

  def models, do: @models
  def voices, do: @voices
  def list_voices, do: {:ok, Enum.map(@voices, &%{id: &1, name: &1})}

  def resolve_config(raw_config) do
    providers = record(record(raw_config)["providers"])

    raw =
      if is_map(providers["xiaomi"]) and not is_struct(providers["xiaomi"]),
        do: providers["xiaomi"],
        else: providers["mimo"]

    normalize(record(raw))
  end

  @doc "Build source-shaped JSON; only the request supplies the HTTP timeout."
  def build_request(request, config) when is_map(request) and is_map(config) do
    config = normalize(config)
    overrides = options(record(request[:provider_overrides]))
    model = overrides[:model] || config.model
    voice = overrides[:voice] || config.voice
    format = overrides[:format] || config.format
    style = overrides[:style] || config[:style]
    design? = model == @design_model
    style = style || if(design?, do: @design_style)
    duration = timer(request[:timeout_ms])
    limit = config[:max_bytes] || @max_bytes

    with true <- is_binary(request[:text]) and String.valid?(request.text),
         true <- is_binary(config[:api_key]) and is_binary(config[:base_url]),
         true <- is_integer(limit) and limit > 0,
         true <- is_nil(request[:deadline_ms]) or is_integer(request[:deadline_ms]) do
      messages =
        if(style, do: [%{"role" => "user", "content" => style}], else: []) ++
          [%{"role" => "assistant", "content" => request.text}]

      audio =
        if design?,
          do: %{"format" => format},
          else: %{"format" => format, "voice" => voice}

      {:ok,
       %{
         method: :post,
         url: config.base_url <> "/chat/completions",
         headers: [{"api-key", config.api_key}, {"content-type", "application/json"}],
         body: %{"model" => model, "messages" => messages, "audio" => audio},
         timeout_ms: duration,
         max_bytes: limit,
         output_format: format,
         file_extension: "." <> format,
         voice_compatible: false
       }
       |> optional(:deadline_ms, request[:deadline_ms])}
    else
      _ -> {:error, :invalid_config}
    end
  end

  def build_request(_, _), do: {:error, :invalid_request}

  def synthesize(request, config) do
    with {:ok, built} <- build_request(request, config) do
      stages = if request[:target] == :voice_note, do: 2, else: 1
      whole_deadline = built[:deadline_ms] || now() + stages * built.timeout_ms
      deadline = min(now() + built.timeout_ms, whole_deadline)

      with {:ok, body} <- http(built, deadline),
           {:ok, audio} <- decode_response(body, built.max_bytes),
           :ok <- within_deadline(whole_deadline) do
        if request[:target] == :voice_note do
          with {:ok, opus} <-
                 Opus.transcode(audio,
                   input_extension: built.output_format,
                   temp_prefix: "tts-xiaomi-",
                   timeout_ms: request[:timeout_ms],
                   timeout_ceiling: @max_timeout,
                   deadline_ms: whole_deadline,
                   max_bytes: built.max_bytes
                 ) do
            {:ok,
             %{
               audio: opus,
               output_format: "opus",
               file_extension: ".opus",
               voice_compatible: true
             }}
          end
        else
          {:ok,
           built
           |> Map.take([:output_format, :file_extension, :voice_compatible])
           |> Map.put(:audio, audio)}
        end
      end
    end
  end

  defp normalize(raw) do
    selected = options(raw)

    %{
      base_url: String.trim_trailing(trim(field(raw, :base_url, "baseUrl")) || @base_url, "/"),
      model: selected[:model] || hd(@models),
      voice: selected[:voice] || hd(@voices),
      format: selected[:format] || "mp3"
    }
    |> optional(:api_key, trim(field(raw, :api_key, "apiKey")))
    |> optional(:style, selected[:style])
    |> optional(:max_bytes, field(raw, :max_bytes, "max_bytes"))
  end

  defp options(raw) do
    %{}
    |> optional(:model, first([field(raw, :model, "model"), field(raw, :model_id, "modelId")]))
    |> optional(
      :voice,
      first([
        field(raw, :speaker_voice, "speakerVoice"),
        field(raw, :speaker_voice_id, "speakerVoiceId"),
        field(raw, :voice, "voice"),
        field(raw, :voice_id, "voiceId")
      ])
    )
    |> optional(:format, format(field(raw, :format, "format")))
    |> optional(:style, trim(field(raw, :style, "style")))
  end

  defp format(value) do
    case trim(value) do
      nil ->
        nil

      value ->
        normalized = String.downcase(value)
        if normalized in ~w(mp3 wav), do: normalized
    end
  end

  defp decode_response(body, limit) do
    with {:ok, root} <- Jason.decode(body),
         [first | _] <- record(root)["choices"],
         message = record(record(first)["message"]),
         encoded when is_binary(encoded) <- trim(record(message["audio"])["data"]),
         {:ok, audio} <- decode_audio(encoded),
         true <- byte_size(audio) <= limit do
      {:ok, audio}
    else
      _ -> {:error, :malformed_audio}
    end
  end

  # The source canonicalizer accepts ASCII controls/space and omitted padding,
  # while retaining the standard alphabet and canonical pad bits.
  defp decode_audio(encoded) do
    cleaned = String.replace(encoded, ~r/[\x00-\x20]/, "")
    remainder = rem(byte_size(cleaned), 4)

    padded =
      cleaned <> if(remainder in [2, 3], do: String.duplicate("=", 4 - remainder), else: "")

    with true <- Regex.match?(~r/\A[A-Za-z0-9+\/]+={0,2}\z/, cleaned),
         true <- remainder == 0 or (remainder in [2, 3] and not String.contains?(cleaned, "=")),
         {:ok, audio} <- Base.decode64(padded),
         true <- Base.encode64(audio) == padded do
      {:ok, audio}
    else
      _ -> {:error, :malformed_audio}
    end
  end

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
      into: fn event, pair -> collect(event, pair, built.max_bytes * 2 + 65_536, deadline) end
    )
    |> Req.request()
    |> response(deadline)
  rescue
    _ -> {:error, :transport}
  catch
    :exit, _ -> {:error, :transport}
  end

  defp collect({:data, data}, {request, response}, limit, deadline) do
    {size, chunks} = Req.Response.get_private(response, :xiaomi_body, {0, []})

    cond do
      remaining(deadline) == 0 ->
        {:halt, {request, Req.Response.put_private(response, :xiaomi_timeout, true)}}

      size + byte_size(data) > limit ->
        {:halt, {request, Req.Response.put_private(response, :xiaomi_limit, true)}}

      true ->
        {:cont,
         {request,
          Req.Response.put_private(
            response,
            :xiaomi_body,
            {size + byte_size(data), [data | chunks]}
          )}}
    end
  end

  defp response({:ok, response}, deadline) do
    cond do
      remaining(deadline) == 0 or Req.Response.get_private(response, :xiaomi_timeout, false) ->
        {:error, :timeout}

      Req.Response.get_private(response, :xiaomi_limit, false) ->
        {:error, :response_too_large}

      response.status not in 200..299 ->
        {:error, {:http_status, response.status}}

      true ->
        {_, chunks} = Req.Response.get_private(response, :xiaomi_body, {0, []})
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  defp response({:error, _}, _), do: {:error, :transport}
  defp timer(value) when is_number(value), do: value |> floor() |> max(1) |> min(@max_timeout)
  defp timer(_), do: 1

  defp within_deadline(deadline),
    do: if(remaining(deadline) > 0, do: :ok, else: {:error, :timeout})

  defp now, do: System.monotonic_time(:millisecond)
  defp remaining(deadline), do: max(deadline - now(), 0)
  defp first(values), do: Enum.find_value(values, &trim/1)

  defp field(raw, host, source),
    do: Map.get(raw, source, Map.get(raw, Atom.to_string(host), Map.get(raw, host)))

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
