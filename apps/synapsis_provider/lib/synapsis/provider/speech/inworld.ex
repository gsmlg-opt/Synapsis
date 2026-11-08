defmodule Synapsis.Provider.Speech.Inworld do
  @moduledoc """
  Explicitly configured, buffered Inworld speech synthesis and voice catalog.

  Raw configuration and Talk callbacks accept source-shaped string keys and return
  atom-key service config. Raw configuration reads only `providers.inworld`.

  Atom-key requests contain `:text`, `:target` (`:audio_file`, `:voice_note` or
  `:telephony`), optional `:timeout_ms`, `:deadline_ms` and `:provider_overrides`. Config accepts
  `:api_key`, `:base_url`, `:voice_id`, `:model_id`, `:temperature` and `:max_bytes`.
  Overrides accept voice, model and temperature. File/note output retains vendor
  format and extension metadata; telephony returns PCM/22050 metadata.

  The complete NDJSON response is bounded before parsing; ordered audio records
  are decoded from canonical Base64 and concatenated without codec conversion.
  The host's decoded byte bound defaults to 16 MiB and encoded body bound is twice
  that value, matching the source defaults. HTTP runs in a linked task with finite
  overall/request deadlines and a 30s idle ceiling through shared Req.Finch. The
  original absolute deadline remains distinct from the transport ceiling, which
  is clipped to the original operation duration. Successful calls join the actual
  HTTP task before returning. `voice:stream` does not expose incremental audio.

  Call from an execution task. This service does not select providers, discover
  credentials, publish media, deliver a stream, or own the native tool lifecycle.
  """

  @base_url "https://api.inworld.ai"
  @voice_id "Sarah"
  @model_id "inworld-tts-1.5-max"
  @models ~w(inworld-tts-1.5-max inworld-tts-1.5-mini inworld-tts-1-max inworld-tts-1)
  @request_keys [:text, :target, :timeout_ms, :deadline_ms, :provider_overrides]
  @config_keys [:api_key, :base_url, :voice_id, :model_id, :temperature, :max_bytes]
  @override_keys [:voice_id, :voice, :model_id, :model, :temperature]
  @output_keys [:output_format, :file_extension, :voice_compatible, :sample_rate]
  @max_timeout 2_147_483_647
  @max_bytes 16 * 1024 * 1024
  @idle_timeout 30_000
  @js_space "[\\x{0009}-\\x{000D}\\x{0020}\\x{00A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}]"
  @js_trim Regex.compile!("\\A#{@js_space}+|#{@js_space}+\\z", "u")

  def models, do: @models

  def metadata do
    %{
      id: "inworld",
      label: "Inworld",
      auto_select_order: 30,
      default_model: @model_id,
      models: @models
    }
  end

  @doc "Normalize only the nested providers.inworld source configuration."
  def resolve_config(raw_config) do
    raw = raw_config |> record() |> Map.get("providers") |> record() |> Map.get("inworld")
    raw = record(raw)

    %{
      base_url: normalize_base(raw["baseUrl"]),
      voice_id: trim(raw["voiceId"]) || @voice_id,
      model_id: trim(raw["modelId"]) || @model_id
    }
    |> optional(:api_key, trim(raw["apiKey"]))
    |> optional(:temperature, temperature(raw["temperature"]))
  end

  @doc "Overlay nonblank canonical Talk options on the normalized nested base."
  def resolve_talk_config(base_tts_config, talk_provider_config) do
    talk = record(talk_provider_config)

    resolve_config(base_tts_config)
    |> optional(:api_key, trim(talk["apiKey"]))
    |> optional(:base_url, if(trim(talk["baseUrl"]), do: normalize_base(talk["baseUrl"])))
    |> optional(:voice_id, trim(talk["voiceId"]))
    |> optional(:model_id, trim(talk["modelId"]))
    |> optional(:temperature, temperature(talk["temperature"]))
  end

  @doc "Project only canonical Talk voice, model and numeric temperature options."
  def resolve_talk_overrides(params) do
    params = record(params)

    %{}
    |> optional(:voice_id, trim(params["voiceId"]))
    |> optional(:model_id, trim(params["modelId"]))
    |> optional(:temperature, temperature(params["temperature"]))
  end

  @spec build_request(map(), map()) :: {:ok, map()} | {:error, term()}
  def build_request(request, config), do: build(request, config, :buffered)

  @spec build_telephony_request(map(), map()) :: {:ok, map()} | {:error, term()}
  def build_telephony_request(request, config), do: build(request, config, :telephony)

  defp build(request, config, operation) do
    with :ok <- options(request, @request_keys, :invalid_request),
         :ok <- options(config, @config_keys, :invalid_config),
         true <- is_binary(request[:text]) and String.valid?(request.text),
         true <-
           operation == :telephony or request[:target] in [:audio_file, :voice_note, :telephony],
         {:ok, timeout} <- timeout(request),
         {:ok, deadline, transport_deadline} <- deadline(timeout, request[:deadline_ms]),
         {:ok, limit} <- byte_limit(config),
         overrides = Map.get(request, :provider_overrides, %{}),
         :ok <- options(overrides, @override_keys, :invalid_overrides),
         {:ok, base_url} <- base_url(config) do
      {audio_config, metadata} =
        output(if(operation == :telephony, do: :telephony, else: request.target))

      body =
        %{
          "text" => request.text,
          "voiceId" =>
            trim(coalesce(overrides[:voice_id], overrides[:voice])) || trim(config[:voice_id]) ||
              @voice_id,
          "modelId" =>
            trim(coalesce(overrides[:model_id], overrides[:model])) || trim(config[:model_id]) ||
              @model_id,
          "audioConfig" => audio_config
        }
        |> optional(
          "temperature",
          temperature(overrides[:temperature]) || temperature(config[:temperature])
        )

      {:ok,
       Map.merge(metadata, %{
         url: base_url <> "/tts/v1/voice:stream",
         headers: [
           {"authorization", "Basic " <> trim(config[:api_key])},
           {"content-type", "application/json"}
         ],
         body: body,
         timeout_ms: timeout,
         deadline_ms: deadline,
         transport_deadline_ms: transport_deadline,
         max_bytes: limit,
         max_response_bytes: limit * 2
       })}
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  @spec synthesize(map(), map()) :: {:ok, map()} | {:error, term()}
  def synthesize(request, config) do
    with {:ok, built} <- build_request(request, config), do: synthesize_built(built)
  end

  @spec synthesize_telephony(map(), map()) :: {:ok, map()} | {:error, term()}
  def synthesize_telephony(request, config) do
    with {:ok, built} <- build_telephony_request(request, config), do: synthesize_built(built)
  end

  defp synthesize_built(built) do
    with {:ok, bytes} <- http(:post, built),
         {:ok, audio} <- decode_ndjson(bytes, built.max_bytes, built.transport_deadline_ms),
         true <- remaining(built.transport_deadline_ms) > 0 do
      {:ok, built |> Map.take(@output_keys) |> Map.put(:audio, audio)}
    else
      false -> {:error, :timeout}
      error -> error
    end
  end

  @doc "Fetch ordered voice options only on an explicit call with current credentials."
  def list_voices(request, config) do
    with :ok <- options(request, ~w(api_key base_url timeout_ms deadline_ms)a, :invalid_request),
         :ok <- options(config, @config_keys, :invalid_config),
         {:ok, timeout} <- timeout(request),
         {:ok, deadline, transport_deadline} <- deadline(timeout, request[:deadline_ms]),
         {:ok, limit} <- byte_limit(config),
         api_key = trim(request[:api_key]) || trim(config[:api_key]),
         base = %{api_key: api_key, base_url: coalesce(request[:base_url], config[:base_url])},
         {:ok, base_url} <- base_url(base),
         {:ok, bytes} <-
           http(:get, %{
             url: base_url <> "/voices/v1/voices",
             headers: [{"authorization", "Basic " <> api_key}],
             body: nil,
             timeout_ms: timeout,
             deadline_ms: deadline,
             transport_deadline_ms: transport_deadline,
             max_bytes: limit,
             max_response_bytes: limit
           }),
         {:ok, json} when is_map(json) <- Jason.decode(bytes),
         voices = project_voices(json["voices"]),
         true <- remaining(transport_deadline) > 0 do
      {:ok, voices}
    else
      false -> {:error, :timeout}
      {:error, %Jason.DecodeError{}} -> {:error, :malformed_response}
      {:ok, _} -> {:error, :malformed_response}
      error -> error
    end
  end

  defp project_voices(voices) when is_list(voices) do
    voices
    |> Enum.map(fn voice ->
      voice = record(voice)
      tags = if is_list(voice["tags"]), do: voice["tags"], else: []

      %{}
      |> optional(:id, trim(voice["voiceId"]))
      |> optional(:name, trim(voice["displayName"]))
      |> optional(:description, trim(voice["description"]))
      |> optional(
        :locale,
        if(is_binary(voice["langCode"]) and voice["langCode"] != "", do: voice["langCode"])
      )
      |> optional(:gender, Enum.find(tags, &(&1 in ["male", "female"])))
    end)
    |> Enum.filter(&is_binary(&1[:id]))
  end

  defp project_voices(_), do: []

  defp output(:audio_file),
    do:
      {%{"audioEncoding" => "MP3"},
       %{output_format: "mp3", file_extension: ".mp3", voice_compatible: false}}

  defp output(:voice_note),
    do:
      {%{"audioEncoding" => "OGG_OPUS"},
       %{output_format: "ogg_opus", file_extension: ".ogg", voice_compatible: true}}

  defp output(:telephony),
    do:
      {%{"audioEncoding" => "PCM", "sampleRateHertz" => 22_050},
       %{output_format: "pcm", sample_rate: 22_050}}

  defp base_url(config) do
    url = normalize_base(config[:base_url])

    with true <- is_binary(trim(config[:api_key])),
         {:ok, %URI{scheme: scheme, host: host}}
         when scheme in ["http", "https"] and is_binary(host) <- URI.new(url) do
      {:ok, url}
    else
      _ -> {:error, :invalid_config}
    end
  end

  defp temperature(value) when is_number(value) and value > 0 and value <= 2, do: value
  defp temperature(_), do: nil

  defp options(value, keys, error) when is_map(value) do
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

  # Keep the effect owner's absolute deadline and the original operation duration
  # separate. Every transport wait and normal parsing step shares this one H.
  defp deadline(timeout, absolute) when is_nil(absolute) or is_integer(absolute) do
    transport = now() + timeout
    deadline = absolute || transport
    transport = min(transport, deadline)
    if remaining(transport) > 0, do: {:ok, deadline, transport}, else: {:error, :timeout}
  end

  defp deadline(_, _), do: {:error, :invalid_deadline}
  defp now, do: System.monotonic_time(:millisecond)
  defp remaining(deadline), do: max(0, deadline - now())

  defp normalize_base(value) do
    case (trim(value) || "") |> String.trim_trailing("/") do
      "" -> @base_url
      root -> root
    end
  end

  defp record(value) when is_map(value) and not is_struct(value), do: value
  defp record(_), do: %{}
  defp coalesce(nil, fallback), do: fallback
  defp coalesce(value, _fallback), do: value

  defp trim(value) when is_binary(value) do
    if String.valid?(value) do
      case Regex.replace(@js_trim, value, "") do
        "" -> nil
        text -> text
      end
    end
  end

  defp trim(_), do: nil
  defp optional(map, _key, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)

  defp http(method, built) do
    case remaining(built.transport_deadline_ms) do
      0 ->
        {:error, :timeout}

      _duration ->
        task = Task.async(fn -> perform(method, built) end)

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

  defp perform(method, built) do
    case remaining(built.transport_deadline_ms) do
      0 -> {:error, :timeout}
      duration -> perform(method, built, duration)
    end
  end

  defp perform(method, built, duration) do
    # Inworld dashboard credentials are already encoded; retain them verbatim.
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
      receive_timeout: min(duration, @idle_timeout),
      request_timeout: duration,
      finch: [pool_timeout: duration]
    )
    |> Req.request()
    |> response(built)
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

      size + byte_size(data) > built.max_response_bytes ->
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

  defp response({:ok, response}, built) do
    cond do
      remaining(built.transport_deadline_ms) == 0 or
          Req.Response.get_private(response, :speech_timeout, false) ->
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

  defp response({:error, _reason}, _built), do: {:error, :transport}

  defp decode_ndjson(body, limit, deadline) do
    if String.valid?(body) do
      body
      |> String.split("\n")
      |> Enum.reduce_while({:ok, 0, []}, fn line, {:ok, size, chunks} ->
        case {remaining(deadline), trim(line)} do
          {0, _} ->
            {:halt, {:error, :timeout}}

          {_, nil} ->
            {:cont, {:ok, size, chunks}}

          {_, line} ->
            with {:ok, row} when is_map(row) <- Jason.decode(line),
                 false <- source_error?(row),
                 {:ok, audio} <- audio_chunk(row, limit - size) do
              chunks = if is_nil(audio), do: chunks, else: [audio | chunks]
              {:cont, {:ok, size + byte_size(audio || ""), chunks}}
            else
              {:error, reason} -> {:halt, {:error, reason}}
              _ -> {:halt, {:error, :malformed_response}}
            end
        end
      end)
      |> decoded_audio()
    else
      {:error, :malformed_response}
    end
  end

  defp source_error?(row), do: Map.get(row, "error") not in [nil, false, 0, ""]

  defp audio_chunk(%{"result" => %{"audioContent" => data}}, limit)
       when is_binary(data) and data != "",
       do: decode_audio(data, limit)

  defp audio_chunk(%{"result" => %{"audioContent" => value}}, _limit)
       when value not in [nil, false, 0, ""],
       do: {:error, :malformed_response}

  defp audio_chunk(_row, _limit), do: {:ok, nil}

  defp decode_audio(data, limit) do
    cleaned = Regex.replace(~r/[\x00-\x20]/, data, "")
    length = byte_size(cleaned)
    remainder = rem(length, 4)

    padding =
      cond do
        String.ends_with?(cleaned, "==") -> 2
        String.ends_with?(cleaned, "=") -> 1
        true -> 0
      end

    canonical = cleaned <> String.duplicate("=", rem(4 - remainder, 4))

    cond do
      div(length * 3, 4) - padding > limit ->
        {:error, :response_too_large}

      cleaned == "" or remainder == 1 or not Regex.match?(~r/\A[A-Za-z0-9+\/]*={0,2}\z/, cleaned) ->
        {:error, :malformed_response}

      remainder != 0 and padding != 0 ->
        {:error, :malformed_response}

      true ->
        with {:ok, bytes} <- Base.decode64(canonical),
             true <- Base.encode64(bytes) == canonical do
          {:ok, bytes}
        else
          _ -> {:error, :malformed_response}
        end
    end
  end

  defp decoded_audio({:ok, _size, [_ | _] = chunks}),
    do: {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

  defp decoded_audio({:ok, _size, []}), do: {:error, :malformed_response}
  defp decoded_audio({:error, _reason} = error), do: error
end
