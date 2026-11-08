defmodule Synapsis.Provider.Speech.Google do
  @moduledoc """
  Explicit Google speech services. Consumers prepare text once before synthesis.

  Saved identity, credentials, native effects and media publication belong to the
  host. This module owns source-shaped callbacks, the two speech JSON APIs and
  buffered audio conversion. It neither discovers ambient credentials nor starts
  an automatic Talk, directive or telephony consumer.
  """

  import Bitwise, only: [band: 2]
  alias __MODULE__.Opus

  @base_url "https://generativelanguage.googleapis.com/v1beta"
  @model "gemini-3.1-flash-tts-preview"
  @models ~w(gemini-3.8-flash-tts gemini-3.8-flash-lite-tts gemini-3.1-flash-tts-preview gemini-2.5-flash-preview-tts gemini-2.5-pro-preview-tts)
  @voices ~w(Zephyr Puck Charon Kore Fenrir Leda Orus Aoede Callirrhoe Autonoe Enceladus Iapetus Umbriel Algieba Despina Erinome Algenib Rasalgethi Laomedeia Achernar Alnilam Schedar Gacrux Pulcherrima Achird Zubenelgenubi Vindemiatrix Sadachbia Sadaltager Sulafat)
  @max_timeout 2_147_483_647
  @max_bytes 16 * 1024 * 1024
  @request_keys ~w(text target timeout_ms provider_overrides deadline_ms)a
  @config_keys ~w(api_key base_url model voice_name voice audio_profile speaker_name speakers prompt_template persona_prompt max_bytes)a
  @override_keys ~w(model voice_name voiceName voice audio_profile audioProfile speaker_name speakerName)a
  @js_space "[\\x{0009}-\\x{000D}\\x{0020}\\x{00A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}]"
  @js_trim Regex.compile!("\\A#{@js_space}+|#{@js_space}+\\z", "u")
  @intro "Synthesize speech from the TRANSCRIPT section only. Use the other sections only\nas performance direction. Do not read section titles, notes, labels, or\nconfiguration aloud."

  def metadata do
    %{
      id: "google",
      label: "Google",
      auto_select_order: 50,
      default_model: @model,
      models: @models,
      voices: @voices
    }
  end

  def models, do: @models
  def voices, do: @voices
  def list_voices, do: {:ok, Enum.map(@voices, &%{id: &1, name: &1})}

  def resolve_config(raw_config) do
    raw_config
    |> record()
    |> Map.get("providers")
    |> record()
    |> Map.get("google")
    |> record()
    |> read_config()
  end

  def resolve_talk_config(base_tts_config, talk_provider_config) do
    base = resolve_config(base_tts_config)
    talk = record(talk_provider_config)

    base =
      if Map.has_key?(talk, "apiKey"),
        do: base |> Map.delete(:api_key) |> put_optional(:api_key, trim(talk["apiKey"])),
        else: base

    base
    |> put_optional(:base_url, trim(talk["baseUrl"]))
    |> put_optional(:model, if(trim(talk["modelId"]), do: normalize_model(talk["modelId"])))
    |> put_optional(:voice_name, trim(talk["voiceId"]))
  end

  def resolve_talk_overrides(params) do
    raw = record(params)

    %{}
    |> put_optional(:voice_name, trim(raw["voiceId"]))
    |> put_optional(:model, if(trim(raw["modelId"]), do: normalize_model(raw["modelId"])))
  end

  @doc "Pure directive interface; policy and dispatch remain with the consumer."
  def parse_directive_token(context) do
    key = context[:key] || context["key"]
    policy = record(context[:policy] || context["policy"])

    rule =
      cond do
        key in ~w(voicename voice_name google_voice googlevoice) -> {:voice_name, :allowVoice}
        key in ~w(google_model googlemodel) -> {:model, :allowModelId}
        true -> nil
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

  @doc "Prepare invocation text explicitly, observing the same effective model as synthesis."
  def prepare_synthesis(context) do
    config = normalize_config(record(context[:provider_config] || context["provider_config"]))
    overrides = read_overrides(context[:provider_overrides] || context["provider_overrides"])
    text = context[:text] || context["text"]
    model = normalize_model(overrides[:model] || config.model)
    :ok = supported_model(model)

    prepared =
      cond do
        interactions?(model) ->
          unwrap_prompt(text)

        (config[:prompt_template] == "audio-profile-v1" or not is_nil(config[:persona_prompt])) and
            not wrapped?(text) ->
          persona = record(context[:persona] || context["persona"])

          label =
            section(persona[:label] || persona["label"]) || section(persona[:id] || persona["id"])

          notes = section(config[:persona_prompt])

          [
            @intro,
            if(label && label != "", do: "# AUDIO PROFILE: " <> label),
            if(notes && notes != "", do: "### DIRECTOR'S NOTES\nProvider notes:\n" <> notes),
            "### TRANSCRIPT\n" <> (trim(newlines(text)) || "")
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.join("\n\n")

        true ->
          nil
      end

    {:ok, if(prepared, do: %{text: prepared})}
  rescue
    _ in ArgumentError -> {:error, :invalid_config}
  end

  @doc "Build the exact API request without HTTP, preparation or audio conversion."
  def build_request(request, config) do
    with :ok <- options(request, @request_keys, :invalid_request),
         :ok <- options(config, @config_keys, :invalid_config),
         true <- is_binary(request[:text]) and String.valid?(request.text),
         true <- request[:target] in [:audio_file, :voice_note, :telephony],
         true <- is_nil(request[:deadline_ms]) or is_integer(request[:deadline_ms]),
         {:ok, timeout} <- timeout(request[:timeout_ms]),
         {:ok, limit} <- byte_limit(config),
         :ok <-
           options(Map.get(request, :provider_overrides, %{}), @override_keys, :invalid_overrides),
         normalized = normalize_config(config),
         key when is_binary(key) <- normalized[:api_key] do
      settings = Map.merge(normalized, read_overrides(request[:provider_overrides]))
      settings = %{settings | model: normalize_model(settings.model)}
      :ok = supported_model(settings.model)
      interactions = interactions?(settings.model)
      dialogue = split_dialogue(request.text, settings[:speakers])

      if dialogue && not interactions do
        {:error, :unsupported_dialogue_model}
      else
        {:ok,
         output(request.target)
         |> Map.merge(%{
           url:
             normalize_base(settings[:base_url]) <>
               if(interactions,
                 do: "/interactions",
                 else: "/models/#{settings.model}:generateContent"
               ),
           headers: [{"x-goog-api-key", key}, {"content-type", "application/json"}],
           body:
             if(interactions,
               do: interactions_body(request.text, settings, dialogue),
               else: generate_body(request.text, settings)
             ),
           model: settings.model,
           api: if(interactions, do: :interactions, else: :generate_content),
           target: request.target,
           timeout_ms: timeout,
           max_bytes: limit
         })
         |> put_optional(:deadline_ms, request[:deadline_ms])}
      end
    else
      false -> {:error, :invalid_request}
      nil -> {:error, :invalid_config}
      error -> error
    end
  rescue
    _ in ArgumentError -> {:error, :invalid_config}
  end

  def synthesize(request, config) do
    with {:ok, built} <- build_request(request, config),
         built = whole_deadline(built, if(request.target == :voice_note, do: 3, else: 2)),
         {:ok, pcm} <- synthesize_pcm(built, 1),
         {:ok, audio} <- convert(pcm, built) do
      {:ok,
       built
       |> Map.take([:output_format, :file_extension, :voice_compatible])
       |> Map.put(:audio, audio)}
    end
  end

  def synthesize_telephony(request, config) do
    with {:ok, built} <- build_request(Map.put(request, :target, :telephony), config),
         {:ok, pcm} <- synthesize_pcm(whole_deadline(built, 2), 1) do
      {:ok, %{audio: pcm, output_format: "pcm", sample_rate: 24_000}}
    end
  end

  defp read_config(raw) do
    %{
      model: normalize_model(raw["model"]),
      voice_name: trim(coalesce(raw["voiceName"], raw["voice"])) || "Kore"
    }
    |> put_optional(:api_key, trim(raw["apiKey"]))
    |> put_optional(:base_url, trim(raw["baseUrl"]))
    |> put_optional(:audio_profile, trim(raw["audioProfile"]))
    |> put_optional(:speaker_name, trim(raw["speakerName"]))
    |> put_optional(:speakers, speakers(raw["speakers"]))
    |> put_optional(:prompt_template, prompt_template(raw["promptTemplate"]))
    |> put_optional(:persona_prompt, trim(raw["personaPrompt"]))
  end

  defp normalize_config(raw) do
    %{
      model: normalize_model(raw[:model]),
      voice_name: trim(coalesce(raw[:voice_name], raw[:voice])) || "Kore"
    }
    |> put_optional(:api_key, trim(raw[:api_key]))
    |> put_optional(:base_url, trim(raw[:base_url]))
    |> put_optional(:audio_profile, trim(raw[:audio_profile]))
    |> put_optional(:speaker_name, trim(raw[:speaker_name]))
    |> put_optional(:speakers, speakers(raw[:speakers]))
    |> put_optional(:prompt_template, prompt_template(raw[:prompt_template]))
    |> put_optional(:persona_prompt, trim(raw[:persona_prompt]))
  end

  defp read_overrides(raw) do
    raw = record(raw)

    %{}
    |> put_optional(:model, trim(raw[:model] || raw["model"]))
    |> put_optional(
      :voice_name,
      trim(coalesce(known(raw, :voice_name, "voiceName"), known(raw, :voice, "voice")))
    )
    |> put_optional(:audio_profile, trim(known(raw, :audio_profile, "audioProfile")))
    |> put_optional(:speaker_name, trim(known(raw, :speaker_name, "speakerName")))
  end

  defp known(raw, key, source) do
    camel_atom =
      case source do
        "voiceName" -> :voiceName
        "audioProfile" -> :audioProfile
        "speakerName" -> :speakerName
        "voice" -> :voice
      end

    coalesce(raw[key], coalesce(raw[camel_atom], raw[source]))
  end

  defp speakers(nil), do: nil

  defp speakers(values) when is_list(values) do
    cast =
      Enum.map(values, fn entry ->
        raw = record(entry)

        name =
          trim(
            coalesce(coalesce(raw[:speaker], raw["speaker"]), coalesce(raw[:name], raw["name"]))
          )

        voice =
          trim(
            coalesce(
              coalesce(raw[:voice], raw["voice"]),
              coalesce(raw[:voice_name], raw["voiceName"])
            )
          )

        if is_nil(name) or is_nil(voice),
          do: raise(ArgumentError, "Google TTS speaker needs name and voice")

        %{speaker: name, voice: voice} |> put_optional(:style, trim(raw[:style] || raw["style"]))
      end)

    if length(cast) != 2 or length(Enum.uniq_by(cast, & &1.speaker)) != 2,
      do: raise(ArgumentError, "Google TTS requires two different speakers")

    cast
  end

  defp speakers(_), do: raise(ArgumentError, "Google TTS speakers must be an array")

  defp prompt_template(value) do
    case trim(value) do
      nil -> nil
      "audio-profile-v1" -> "audio-profile-v1"
      _ -> raise ArgumentError, "Invalid Google TTS promptTemplate"
    end
  end

  defp normalize_model(value) do
    model = trim(value) || @model

    model =
      if String.starts_with?(model, "google/"), do: String.slice(model, 7..-1//1), else: model

    if model == "gemini-3.1-flash-tts", do: @model, else: model
  end

  defp supported_model(model) do
    if not interactions?(model) and String.contains?(model, "gemini-3.8-") and
         String.contains?(model, "-tts"),
       do: raise(ArgumentError, "Unsupported Google 3.8 TTS model")

    :ok
  end

  defp interactions?(model), do: model in ["gemini-3.8-flash-tts", "gemini-3.8-flash-lite-tts"]

  defp wrapped?(text),
    do:
      String.starts_with?(text, "Synthesize speech from the TRANSCRIPT section only.") and
        String.contains?(text, "# AUDIO PROFILE:") and String.contains?(text, "### TRANSCRIPT")

  defp unwrap_prompt(text) do
    if wrapped?(text) do
      case Regex.run(~r/\n\n### TRANSCRIPT(?:\n|$)/u, text, return: :index) do
        [{offset, size}] ->
          trim(binary_part(text, offset + size, byte_size(text) - offset - size))

        _ ->
          nil
      end
    end
  end

  defp section(value) do
    case trim(if(is_binary(value), do: newlines(value))) do
      nil -> nil
      value -> Regex.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u, value, "")
    end
  end

  defp newlines(text), do: String.replace(text, ~r/\r\n?/, "\n")

  defp split_dialogue(_text, nil), do: nil

  defp split_dialogue(text, cast) do
    names = Enum.map(cast, & &1.speaker)

    {turns, _lead} =
      text
      |> newlines()
      |> String.split("\n")
      |> Enum.reduce({[], []}, fn line, {turns, lead} = state ->
        case trim(line) do
          nil ->
            state

          line ->
            labeled =
              case Regex.run(~r/^([^:\n]{1,80}):([\s\S]*)$/u, line) do
                [_, name, spoken] -> {trim(name), trim(spoken)}
                _ -> nil
              end

            case labeled do
              {name, spoken} ->
                if name in names do
                  if spoken do
                    turns =
                      if turns == [] and lead != [],
                        do: [%{speaker: name, text: Enum.join(lead, " ")}],
                        else: turns

                    {append_turn(turns, name, spoken), []}
                  else
                    state
                  end
                else
                  append_prose(turns, lead, line)
                end

              _ ->
                append_prose(turns, lead, line)
            end
        end
      end)

    if turns != [], do: Enum.reverse(turns)
  end

  defp append_prose([], lead, line), do: {[], lead ++ [line]}

  defp append_prose([%{speaker: name} | _] = turns, lead, line),
    do: {append_turn(turns, name, line), lead}

  defp append_turn([%{speaker: speaker, text: previous} | rest], speaker, text),
    do: [%{speaker: speaker, text: previous <> " " <> text} | rest]

  defp append_turn(turns, speaker, text), do: [%{speaker: speaker, text: text} | turns]

  defp generate_body(text, settings) do
    composed =
      [
        settings[:audio_profile],
        if(settings[:speaker_name], do: "Speaker name: " <> settings.speaker_name),
        text
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    %{
      "contents" => [%{"role" => "user", "parts" => [%{"text" => composed}]}],
      "generationConfig" => %{
        "responseModalities" => ["AUDIO"],
        "speechConfig" => %{
          "voiceConfig" => %{"prebuiltVoiceConfig" => %{"voiceName" => settings.voice_name}}
        }
      }
    }
  end

  defp interactions_body(text, settings, dialogue) do
    {content, speech_config} =
      if dialogue do
        blocks =
          Enum.map(dialogue, fn turn ->
            cast = Enum.find(settings.speakers, &(&1.speaker == turn.speaker))

            annotation =
              %{"type" => "speech_metadata", "speaker" => turn.speaker}
              |> put_optional(
                "style",
                style([cast[:style], settings[:audio_profile], settings[:persona_prompt]])
              )

            %{"type" => "text", "text" => turn.text, "annotations" => [annotation]}
          end)

        {blocks,
         %{
           "mode" => "conversational",
           "speakers" =>
             Enum.map(settings.speakers, &%{"speaker" => &1.speaker, "voice" => &1.voice})
         }}
      else
        annotation =
          %{"type" => "speech_metadata"}
          |> put_optional("speaker", settings[:speaker_name])
          |> put_optional("style", style([settings[:audio_profile], settings[:persona_prompt]]))

        block = %{"type" => "text", "text" => text}

        block =
          if map_size(annotation) > 1,
            do: Map.put(block, "annotations", [annotation]),
            else: block

        {[block], [%{"voice" => settings.voice_name}]}
      end

    %{
      "model" => settings.model,
      "store" => false,
      "input" => [%{"type" => "user_input", "content" => content}],
      "response_format" => %{
        "type" => "audio",
        "mime_type" => "audio/l16",
        "sample_rate" => 24_000
      },
      "generation_config" => %{"speech_config" => speech_config}
    }
  end

  defp style(parts),
    do: parts |> Enum.map(&trim/1) |> Enum.reject(&is_nil/1) |> Enum.join("\n\n") |> trim()

  defp normalize_base(value) do
    base = String.trim_trailing(trim(value) || @base_url, "/")

    case URI.new(base) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when scheme in ["http", "https"] and is_binary(host) ->
        path = String.trim_trailing(uri.path || "", "/")

        path =
          if scheme == "https" and String.downcase(host) == "generativelanguage.googleapis.com",
            do: Regex.replace(~r/\/openai$/i, path, ""),
            else: path

        path =
          if path == "" and scheme == "https" and
               String.downcase(host) == "generativelanguage.googleapis.com",
             do: "/v1beta",
             else: path

        %{uri | host: String.downcase(host), path: path, query: nil, fragment: nil, userinfo: nil}
        |> URI.to_string()
        |> String.trim_trailing("/")

      _ ->
        raise ArgumentError, "Invalid Google speech base URL"
    end
  end

  defp output(:voice_note),
    do: %{output_format: "opus", file_extension: ".opus", voice_compatible: true}

  defp output(_), do: %{output_format: "wav", file_extension: ".wav", voice_compatible: false}

  defp whole_deadline(built, stages),
    do:
      Map.put(
        built,
        :deadline_ms,
        min(
          now() + stages * built.timeout_ms,
          built[:deadline_ms] || now() + stages * built.timeout_ms
        )
      )

  defp synthesize_pcm(built, attempt) do
    deadline = min(now() + built.timeout_ms, built.deadline_ms)

    result =
      with {:ok, bytes} <- http(built, deadline),
           {:ok, payload} <- decode_json(bytes),
           {:ok, encoded} <- encoded_audio(payload, built.api),
           {:ok, audio} <- decode_audio(encoded),
           {:ok, pcm} <- strip_wav(audio),
           :ok <- pcm_limit(pcm, built.max_bytes),
           :ok <- within_deadline(deadline),
           do: {:ok, pcm}

    case result do
      {:error, reason} when attempt < 2 ->
        if retryable?(reason) and remaining(built.deadline_ms) > 0,
          do: synthesize_pcm(built, attempt + 1),
          else: result

      _ ->
        result
    end
  end

  defp http(built, deadline) do
    case remaining(deadline) do
      0 ->
        {:error, :timeout}

      duration ->
        task = Task.async(fn -> perform(built, deadline, duration) end)

        case Task.yield(task, remaining(deadline)) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> completed_task(task.pid, result, deadline)
          nil -> {:error, :timeout}
          {:exit, _} -> {:error, :transport}
        end
    end
  end

  defp completed_task(pid, result, deadline) do
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

  defp perform(built, deadline, duration) do
    Req.Request.new()
    |> Req.Steps.attach()
    |> Req.merge(
      method: :post,
      url: built.url,
      headers: built.headers,
      body: Jason.encode!(built.body),
      raw: true,
      compressed: false,
      retry: false,
      redirect: false,
      receive_timeout: duration,
      request_timeout: duration,
      finch: [pool_timeout: duration],
      into: fn event, pair -> collect(event, pair, built.max_bytes * 2 + 65_536, deadline) end
    )
    |> Req.request()
    |> response(deadline)
  rescue
    exception -> {:error, {:transport, exception}}
  catch
    :exit, reason -> {:error, {:transport, reason}}
  end

  defp collect({:data, data}, {request, response}, limit, deadline) do
    {size, chunks} = Req.Response.get_private(response, :google_speech_body, {0, []})

    cond do
      remaining(deadline) == 0 ->
        {:halt, {request, Req.Response.put_private(response, :google_speech_timeout, true)}}

      size + byte_size(data) > limit ->
        {:halt, {request, Req.Response.put_private(response, :google_speech_limit, true)}}

      true ->
        {:cont,
         {request,
          Req.Response.put_private(
            response,
            :google_speech_body,
            {size + byte_size(data), [data | chunks]}
          )}}
    end
  end

  defp response({:ok, response}, deadline) do
    cond do
      Req.Response.get_private(response, :google_speech_timeout, false) or
          remaining(deadline) == 0 ->
        {:error, :timeout}

      Req.Response.get_private(response, :google_speech_limit, false) ->
        {:error, :response_too_large}

      response.status not in 200..299 ->
        {:error, {:http_status, response.status}}

      true ->
        {_, chunks} = Req.Response.get_private(response, :google_speech_body, {0, []})
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  defp response({:error, reason}, _deadline), do: {:error, {:transport, reason}}
  defp retryable?({:http_status, status}), do: status in 500..599
  defp retryable?(reason) when reason in [:timeout, :missing_audio], do: true

  defp retryable?({:transport, reason}) do
    message = if is_exception(reason), do: Exception.message(reason), else: inspect(reason)
    message = String.downcase(message)

    google_retryable =
      Enum.any?(["aborted", "timeout", "fetch failed", "network"], &String.contains?(message, &1))

    nested = String.downcase(inspect(reason))

    transient =
      not String.contains?(nested, "err_websocket_non_retryable_close") and
        Enum.any?(
          [
            "econnreset",
            "econnrefused",
            "enotfound",
            "etimedout",
            "esockettimedout",
            "econnaborted",
            "epipe",
            "enetdown",
            "ehostunreach",
            "enetunreach",
            "eaddrnotavail",
            "eai_again",
            "eproto",
            "und_err_connect",
            "und_err_dns_resolve_failed",
            "und_err_socket",
            "und_err_headers_timeout",
            "und_err_body_timeout",
            "err_http2_invalid_session",
            "err_ssl_wrong_version_number",
            "err_ssl_protocol_returned_an_error",
            "err_websocket_transport",
            "aborterror",
            "connecttimeouterror",
            "headerstimeouterror",
            "bodytimeouterror",
            "timeouterror",
            "getaddrinfo",
            "socket hang up",
            "temporary failure in name resolution",
            "upstream connect error",
            "disconnect/reset before headers",
            "tlsv1 alert",
            "ssl routines",
            "packet length too long"
          ],
          &String.contains?(nested, &1)
        )

    google_retryable or transient
  end

  defp retryable?(_), do: false

  defp decode_json(<<0xEF, 0xBB, 0xBF, body::binary>>), do: decode_json(body)

  defp decode_json(body) do
    case Jason.decode(body) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      _ -> {:error, :malformed_response}
    end
  end

  defp encoded_audio(payload, :generate_content) do
    coalesce(payload["candidates"], [])
    |> Enum.flat_map(fn candidate ->
      candidate |> record() |> Map.get("content") |> record() |> Map.get("parts") |> coalesce([])
    end)
    |> Enum.find_value(fn part ->
      part = record(part)
      coalesce(part["inlineData"], part["inline_data"]) |> record() |> Map.get("data") |> trim()
    end)
    |> audio_found()
  end

  defp encoded_audio(payload, :interactions) do
    direct =
      trim(
        coalesce(record(payload["output_audio"])["data"], record(payload["outputAudio"])["data"])
      )

    encoded =
      direct ||
        Enum.find_value(coalesce(payload["steps"], []), fn step ->
          Enum.find_value(coalesce(record(step)["content"], []), fn block ->
            block = record(block)
            mime = coalesce(block["mimeType"], block["mime_type"])

            if block["type"] == "audio" or
                 (is_binary(mime) and String.starts_with?(mime, "audio/")),
               do: trim(block["data"])
          end)
        end)

    audio_found(encoded)
  end

  defp audio_found(nil), do: {:error, :missing_audio}
  defp audio_found(value), do: {:ok, value}

  defp pcm_limit(pcm, limit),
    do: if(byte_size(pcm) <= limit, do: :ok, else: {:error, :response_too_large})

  defp decode_audio(encoded) do
    standard? = String.contains?(encoded, ["+", "/"])
    url? = String.contains?(encoded, ["-", "_"])

    cleaned =
      encoded
      |> String.replace("-", "+")
      |> String.replace("_", "/")
      |> String.replace(~r/[\x00-\x20]/, "")

    remainder = rem(byte_size(cleaned), 4)

    padded =
      cleaned <> if(remainder in [2, 3], do: String.duplicate("=", 4 - remainder), else: "")

    with false <- standard? and url?,
         true <- Regex.match?(~r/\A[A-Za-z0-9+\/]+={0,2}\z/, cleaned),
         true <- remainder == 0 or (remainder in [2, 3] and not String.contains?(cleaned, "=")),
         {:ok, decoded} <- Base.decode64(padded),
         true <- Base.encode64(decoded) == padded do
      {:ok, decoded}
    else
      _ -> {:error, :malformed_audio}
    end
  end

  defp strip_wav(<<"RIFF", _::binary-size(4), "WAVE", chunks::binary>>), do: wav_chunks(chunks)
  defp strip_wav(audio), do: {:ok, audio}

  defp wav_chunks(<<"data", size::little-unsigned-32, rest::binary>>),
    do: {:ok, binary_part(rest, 0, min(size, byte_size(rest)))}

  defp wav_chunks(<<_id::binary-size(4), size::little-unsigned-32, rest::binary>>) do
    skip = size + band(size, 1)

    if skip <= byte_size(rest),
      do: wav_chunks(binary_part(rest, skip, byte_size(rest) - skip)),
      else: {:error, :missing_pcm}
  end

  defp wav_chunks(_), do: {:error, :missing_pcm}

  defp wav(pcm),
    do:
      <<"RIFF", 36 + byte_size(pcm)::little-unsigned-32, "WAVEfmt ", 16::little-unsigned-32,
        1::little-unsigned-16, 1::little-unsigned-16, 24_000::little-unsigned-32,
        48_000::little-unsigned-32, 2::little-unsigned-16, 16::little-unsigned-16, "data",
        byte_size(pcm)::little-unsigned-32, pcm::binary>>

  defp convert(pcm, built) do
    with true <- byte_size(pcm) <= built.max_bytes,
         :ok <- within_deadline(built.deadline_ms) do
      if built.target == :voice_note,
        do:
          Opus.transcode(wav(pcm),
            timeout_ms: built.timeout_ms,
            deadline_ms: built.deadline_ms,
            max_bytes: built.max_bytes
          ),
        else: {:ok, wav(pcm)}
    else
      false -> {:error, :response_too_large}
      error -> error
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

  defp options(value, keys, error) when is_map(value) and not is_struct(value),
    do: if(Enum.all?(Map.keys(value), &(&1 in keys)), do: :ok, else: {:error, error})

  defp options(_, _, error), do: {:error, error}

  defp within_deadline(deadline),
    do: if(remaining(deadline) > 0, do: :ok, else: {:error, :timeout})

  defp now, do: System.monotonic_time(:millisecond)
  defp remaining(deadline), do: max(0, deadline - now())
  defp coalesce(nil, fallback), do: fallback
  defp coalesce(value, _fallback), do: value
  defp record(value) when is_map(value) and not is_struct(value), do: value
  defp record(_), do: %{}
  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp trim(value) when is_binary(value) do
    if String.valid?(value) do
      case Regex.replace(@js_trim, value, "") do
        "" -> nil
        value -> value
      end
    end
  end

  defp trim(_), do: nil
end
