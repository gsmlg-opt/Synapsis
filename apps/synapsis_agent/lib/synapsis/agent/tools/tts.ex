defmodule Synapsis.Agent.Tools.TTS do
  @moduledoc """
  Selected speech synthesis with explicitly configured providers and durable audio.

  The native effect owner performs synthesis once, publishes immutable audio, and
  settles the transcript, portable media descriptor and durable delivery reference.
  Resolved credentials and audio bytes remain invocation-local; playback is
  initiated separately by the user.
  """
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.{Error, InputSchema, ToolCatalog, ToolEffects, ToolRegistry}
  alias Backplane.AgentRuntime.Codex.Session
  alias Synapsis.Agent.MediaDelivery
  alias Synapsis.Agent.Tools.CatalogBinding
  alias Synapsis.Config.Store, as: ConfigStore

  alias Synapsis.Provider.Speech.{
    Azure,
    ClawRouter,
    DeepInfra,
    ElevenLabs,
    FishAudio,
    Gradium,
    Google,
    Inworld,
    OpenAI,
    OpenRouter,
    Vydra,
    Xiaomi,
    XAI
  }

  alias Synapsis.Workspace.Media
  alias Synapsis.{AgentConfig, AgentConfigs, Providers}

  @name "synapsis::tts"
  @keys ~w(identity agent_id agent_name fingerprint provider_id provider_name provider_fingerprint timing media_root session_binding)a
  @native_keys ~w(interact effect_deadline append_feedback emit catalog_snapshot stage_catalog request_new_context nested_dispatch register_cancellation register_code_mode cancellation_coordinator resource_owner_pid goal goal_binding)a
  @config_keys ~w(provider model voice speed instructions response_format extra_body max_bytes media_root voice_id model_id seed apply_text_normalization language_code voice_settings output_format latency_tier language temperature timeout_ms reference_id latency top_p normalize voice_name audio_profile speaker_name speakers prompt_template persona_prompt lang voice_note_output_format speaker_voice speaker_voice_id format style)
  @speech_keys ~w(model voice speed instructions response_format extra_body max_bytes)a
  @xai_keys ~w(voice_id language speed response_format max_bytes)a
  @gradium_keys ~w(voice_id max_bytes)a
  @openrouter_keys ~w(model voice speed response_format)a
  @deepinfra_keys ~w(model voice speed response_format)a
  @vydra_keys ~w(model voice_id)a
  @provider_types ~w(openai openai_compat openai_responses groq elevenlabs openai_speech xai_speech inworld_speech gradium_speech openrouter_speech deepinfra_speech vydra_speech fish_audio_speech google_speech azure_speech xiaomi_speech clawrouter_speech)
  @timeout 30_000
  @max_timeout 2_147_483_647
  @publication_timeout 5_000
  @max_bytes 16 * 1024 * 1024

  def names, do: [@name]
  def permission_level(@name), do: :execute

  def tool_effect_timeout(%{tool_name: @name, tool_revision: 1} = invocation, %{
        catalog_snapshot: %{registry: registry}
      }) do
    with {:ok, %{backend: __MODULE__, tool_revision: 1, backend_context: %{timing: timing}}} <-
           ToolRegistry.lookup(registry, @name),
         {:ok, arguments} <- InputSchema.validate(schema(), invocation.arguments),
         {:ok, timeout} <- synthesis_timeout(arguments, timing) do
      stages = Map.get(timing, :stage_count, 1)
      {:ok, min(stages * timeout + @publication_timeout, @max_timeout)}
    else
      {:error, %Error{}} = error -> error
      _ -> failure(:validation, "TTS timing descriptor is unavailable")
    end
  end

  def tool_effect_timeout(%{tool_name: @name}, _),
    do: failure(:validation, "TTS timing descriptor is unavailable")

  def tool_effect_timeout(_, _), do: :default

  def bundles(context, identity, authority, selection, binding) do
    if @name in selection do
      with true <- @name in authority.grants,
           {:ok, agent, config, provider, root} <- configuration(context.agent[:name]),
           trusted = %{
             identity: identity,
             agent_id: agent.id,
             agent_name: agent.name,
             fingerprint: fingerprint(agent, config, provider, root),
             provider_id: provider.id,
             provider_name: provider.name,
             provider_fingerprint: provider_fingerprint(provider),
             timing: timing(config, provider),
             media_root: root,
             session_binding: binding
           },
           ceiling = %{
             authority
             | grants: [@name],
               tool_revisions: Map.take(authority.tool_revisions, [@name])
           },
           {:ok, bundle} <-
             ToolCatalog.admit_batch([descriptor(trusted)], authority: ceiling, mode: :strict) do
        {:ok, [bundle]}
      else
        false -> failure(:forbidden, "TTS exceeds the parent authority ceiling")
        {:error, %Error{}} = error -> error
        _ -> unavailable()
      end
    else
      {:ok, []}
    end
  end

  def classify(%{backend: __MODULE__, backend_context: context}, identity, operation) do
    with true <- context.identity === identity,
         {:ok, input, _speech} <- invocation(context, operation) do
      {:ok,
       %{
         action: "tts.synthesize",
         resource: "tts:" <> digest({context.agent_id, context.provider_id, input.text}),
         permission_level: :execute
       }}
    else
      false -> failure(:forbidden, "TTS invocation scope changed")
      error -> error
    end
  end

  def classify(_, _, _), do: failure(:validation, "TTS descriptor is unavailable")

  @impl true
  def execute(%{backend_context: enriched} = operation) do
    context = Map.take(enriched, @keys)

    with {:ok, input, speech} <- invocation(context, operation) do
      execute_ready(input, speech, context, operation)
    else
      {:error, %Error{} = error} -> ToolEffects.reject(operation, error)
      _ -> failure(:execution_failure, "TTS synthesis is unavailable")
    end
  rescue
    _ -> uncertain()
  catch
    :exit, _ -> uncertain()
  end

  def execute(_), do: failure(:validation, "TTS context is unavailable")

  @impl true
  # Native cancellation ends this effect owner and the speech adapter's linked
  # HTTP owner. Published immutable media belongs to Workspace, not this run.
  def cancel(_operation), do: :ok

  defp invocation(context, operation) do
    with true <- Enum.sort(Map.keys(context)) == Enum.sort(@keys),
         true <- operation[:tool_name] === @name,
         :ok <-
           CatalogBinding.host(context, operation, __MODULE__, 1, @native_keys, context.identity),
         {:ok, _} <- Session.validate(context.session_binding, operation),
         {:ok, agent, config, provider, root} <- configuration(context.agent_name),
         true <-
           agent.id === context.agent_id and provider.id === context.provider_id and
             provider.name === context.provider_name and root === context.media_root and
             fingerprint(agent, config, provider, root) === context.fingerprint and
             provider_fingerprint(provider) === context.provider_fingerprint and
             timing(config, provider) === context.timing,
         {:ok, arguments} <- InputSchema.validate(schema(), operation.arguments),
         {:ok, input} <- normalize(arguments, context.timing),
         {:ok, runtime} <- Providers.runtime_config(provider.name),
         true <- runtime[:provider_id] === context.provider_id,
         speech = prepare_speech(input.request, config, runtime, provider),
         {:ok, _} <- build_speech(speech) do
      {:ok, input, speech}
    else
      false -> failure(:forbidden, "TTS configuration changed; prepare a new run")
      {:error, %Error{}} = error -> error
      _ -> failure(:validation, "TTS invocation is unavailable")
    end
  end

  defp configuration(name) do
    with %AgentConfig{enabled: true, config: %{"tts" => config}} = agent <-
           AgentConfigs.get_by_name(name),
         true <- is_map(config) and not is_struct(config),
         config = Map.take(config, @config_keys),
         provider_name when is_binary(provider_name) and provider_name != "" <-
           config["provider"],
         {:ok, provider} <- Providers.get_by_name(provider_name),
         true <- provider.type in @provider_types and Providers.runtime_available?(provider),
         {:ok, root} <- media_root(config),
         true <- valid_options?(config, provider.type),
         {:ok, runtime} <- Providers.runtime_config(provider.name),
         true <- runtime[:provider_id] === provider.id,
         {:ok, _} <-
           build_speech(
             prepare_speech(
               %{
                 text:
                   if(provider.type == "clawrouter_speech",
                     do: "Configuration preflight.",
                     else: ""
                   ),
                 target: :audio_file
               },
               config,
               runtime,
               provider
             )
           ) do
      {:ok, agent, config, provider, root}
    else
      _ -> unavailable()
    end
  end

  defp media_root(config) do
    root = Map.get(config, "media_root", Path.join(ConfigStore.config_dir(), "media"))

    if is_binary(root) and root != "" and String.valid?(root) and
         not String.contains?(root, <<0>>) and Path.type(root) == :absolute,
       do: {:ok, Path.expand(root)},
       else: unavailable()
  end

  defp valid_options?(config, type) do
    Enum.all?(~w(model voice instructions response_format), fn key ->
      not Map.has_key?(config, key) or
        (is_binary(config[key]) and String.valid?(config[key]))
    end) and
      (not Map.has_key?(config, "speed") or is_number(config["speed"])) and
      (not Map.has_key?(config, "timeout_ms") or
         ((is_integer(config["timeout_ms"]) or
             (type == "azure_speech" and is_number(config["timeout_ms"]))) and
            config["timeout_ms"] > 0)) and
      (not Map.has_key?(config, "max_bytes") or
         (is_integer(config["max_bytes"]) and config["max_bytes"] > 0)) and
      (type != "xiaomi_speech" or
         Enum.all?(~w(model_id speaker_voice speaker_voice_id voice_id format style), fn key ->
           not Map.has_key?(config, key) or
             (is_binary(config[key]) and String.valid?(config[key]))
         end))
  end

  defp timing(config, %{type: "azure_speech"} = provider) do
    case Providers.azure_speech_config(provider.id, config) do
      {:ok, prepared} ->
        timing = %{default_timeout_ms: @timeout}

        case Map.fetch(prepared.config, :timeout_ms) do
          {:ok, timeout} -> Map.put(timing, :azure_provider_timeout_ms, timeout)
          :error -> timing
        end

      _ ->
        %{default_timeout_ms: @timeout}
    end
  end

  defp timing(config, provider) do
    default =
      case provider.type do
        "openrouter_speech" ->
          OpenRouter.default_timeout_ms()

        "deepinfra_speech" ->
          DeepInfra.default_timeout_ms()

        "google_speech" ->
          case Providers.google_speech_config(provider.id) do
            {:ok, prepared} -> prepared.timeout_ms
            _ -> @timeout
          end

        "fish_audio_speech" ->
          case Providers.fish_audio_config(provider.id) do
            {:ok, prepared} -> prepared.timeout_ms
            _ -> FishAudio.default_timeout_ms()
          end

        _ ->
          @timeout
      end

    timing = %{default_timeout_ms: default}

    timing =
      if provider.type in ["vydra_speech", "google_speech"],
        do: Map.put(timing, :stage_count, 2),
        else: timing

    case Map.fetch(config, "timeout_ms") do
      {:ok, timeout} -> Map.put(timing, :configured_timeout_ms, timeout)
      :error -> timing
    end
  end

  # Presence preserves explicit Agent 30000 independently of the ordinary
  # fallback's numeric value. Clamp only when constructing runtime timers.
  defp synthesis_timeout(_arguments, %{azure_provider_timeout_ms: timeout})
       when is_number(timeout) and timeout > 0 do
    {:ok, min(ceil(timeout), @max_timeout)}
  end

  defp synthesis_timeout(arguments, %{default_timeout_ms: default} = timing) do
    timeout =
      Map.get(arguments, "timeoutMs", Map.get(timing, :configured_timeout_ms, default))

    if is_integer(timeout) and timeout > 0,
      do: {:ok, min(timeout, @max_timeout)},
      else: failure(:validation, "TTS timeout must be a positive integer")
  end

  defp synthesis_timeout(_, _), do: failure(:validation, "TTS timing descriptor is unavailable")

  defp normalize(arguments, timing) do
    text = String.trim(arguments["text"])
    channel = arguments |> Map.get("channel", "") |> String.trim()

    cond do
      text == "" ->
        failure(:validation, "TTS text is required")

      channel != "" ->
        failure(:unsupported_capability, "TTS supports local audio files without a channel")

      true ->
        with {:ok, timeout} <- synthesis_timeout(arguments, timing) do
          {:ok,
           %{
             text: text,
             timeout: timeout,
             supplied_timeout: arguments["timeoutMs"],
             request: %{text: text, target: :audio_file, timeout_ms: timeout}
           }}
        end
    end
  end

  defp speech_config(config, runtime) do
    # Saved provider roots follow the shared adapter's API-root convention;
    # the speech service receives the resulting versioned API prefix.
    runtime =
      case runtime[:base_url] do
        base_url when is_binary(base_url) and base_url != "" ->
          root = base_url |> String.trim() |> String.trim_trailing("/")
          prefix = if String.ends_with?(root, "/v1"), do: root, else: root <> "/v1"
          Map.put(runtime, :base_url, prefix)

        _ ->
          runtime
      end

    raw =
      Enum.reduce(@speech_keys, Map.take(runtime, [:api_key, :base_url]), fn key, speech ->
        case Map.fetch(config, Atom.to_string(key)) do
          {:ok, value} -> Map.put(speech, key, value)
          :error -> speech
        end
      end)

    raw
    |> Map.new(fn
      {:api_key, value} -> {"apiKey", value}
      {:base_url, value} -> {"baseUrl", value}
      {:response_format, value} -> {"responseFormat", value}
      {:extra_body, value} -> {"extraBody", value}
      {key, value} -> {Atom.to_string(key), value}
    end)
    |> OpenAI.resolve_config()
    |> Map.put(:max_bytes, Map.get(raw, :max_bytes, @max_bytes))
  end

  defp prepare_speech(request, config, _runtime, %{type: "elevenlabs"} = provider) do
    overrides =
      for key <- ~w(output_format latency_tier),
          Map.has_key?(config, key),
          into: %{},
          do: {String.to_existing_atom(key), config[key]}

    speech =
      case Providers.elevenlabs_speech_config(provider.id, config) do
        {:ok, %{provider_id: id, provider_name: name} = prepared}
        when id == provider.id and name == provider.name ->
          prepared.config

        _ ->
          %{}
      end

    %{
      adapter: ElevenLabs,
      provider: "elevenlabs",
      request: Map.put(request, :provider_overrides, overrides),
      config: speech
    }
  end

  defp prepare_speech(request, config, runtime, %{type: "xai_speech"}) do
    speech =
      Enum.reduce(
        @xai_keys,
        Map.take(runtime, [:api_key, :base_url | @xai_keys]),
        fn key, speech ->
          case Map.fetch(config, Atom.to_string(key)) do
            {:ok, value} -> Map.put(speech, key, value)
            :error -> speech
          end
        end
      )
      |> Map.put_new(:max_bytes, @max_bytes)

    %{adapter: XAI, provider: "xai", request: request, config: speech}
  end

  defp prepare_speech(request, config, _runtime, %{type: "inworld_speech"} = provider) do
    speech =
      case Providers.inworld_speech_config(provider.id, config) do
        {:ok, %{provider_id: id, provider_name: name} = prepared}
        when id == provider.id and name == provider.name ->
          prepared.config

        _ ->
          %{}
      end

    %{adapter: Inworld, provider: "inworld", request: request, config: speech}
  end

  defp prepare_speech(request, config, runtime, %{type: "gradium_speech"}) do
    speech =
      Enum.reduce(
        @gradium_keys,
        Map.take(runtime, [:api_key, :base_url | @gradium_keys]),
        fn key, speech ->
          case Map.fetch(config, Atom.to_string(key)) do
            {:ok, value} -> Map.put(speech, key, value)
            :error -> speech
          end
        end
      )
      |> Map.put_new(:max_bytes, @max_bytes)

    %{adapter: Gradium, provider: "gradium", request: request, config: speech}
  end

  defp prepare_speech(request, config, runtime, %{type: "openrouter_speech"} = provider) do
    # Translate only known saved fields. Nested vendor routing retains its
    # original string keys and current credentials remain invocation-local.
    raw =
      Enum.reduce(
        [
          {"model", :model},
          {"modelId", :model_id},
          {"voice", :voice},
          {"voiceId", :voice_id},
          {"speakerVoice", :speaker_voice},
          {"speakerVoiceId", :speaker_voice_id},
          {"speed", :speed},
          {"responseFormat", :response_format},
          {"provider", :provider}
        ],
        %{},
        fn {source, host}, raw ->
          case saved_setting(provider.config || %{}, source, host) do
            {:ok, value} -> Map.put(raw, source, value)
            :error -> raw
          end
        end
      )
      |> Map.put("apiKey", runtime[:api_key])
      |> Map.put("baseUrl", runtime[:base_url])

    saved = OpenRouter.resolve_config(%{"providers" => %{"openrouter" => raw}})

    speech =
      Enum.reduce(@openrouter_keys, saved, fn key, speech ->
        case Map.fetch(config, Atom.to_string(key)) do
          {:ok, value} -> Map.put(speech, key, value)
          :error -> speech
        end
      end)
      |> Map.put(:max_bytes, Map.get(config, "max_bytes", runtime[:max_bytes] || @max_bytes))

    %{adapter: OpenRouter, provider: "openrouter", request: request, config: speech}
  end

  defp prepare_speech(request, config, runtime, %{type: "deepinfra_speech"} = provider) do
    # Translate only known saved fields. Nested extraBody values retains its
    # original string keys and current credentials remain invocation-local.
    raw =
      Enum.reduce(
        [
          {"model", :model},
          {"modelId", :model_id},
          {"voice", :voice},
          {"voiceId", :voice_id},
          {"speakerVoice", :speaker_voice},
          {"speakerVoiceId", :speaker_voice_id},
          {"speed", :speed},
          {"responseFormat", :response_format},
          {"extraBody", :extra_body}
        ],
        %{},
        fn {source, host}, raw ->
          case saved_setting(provider.config || %{}, source, host) do
            {:ok, value} -> Map.put(raw, source, value)
            :error -> raw
          end
        end
      )
      |> Map.put("apiKey", runtime[:api_key])
      |> Map.put("baseUrl", runtime[:base_url])

    saved = DeepInfra.resolve_config(%{"providers" => %{"deepinfra" => raw}})

    speech =
      Enum.reduce(@deepinfra_keys, saved, fn key, speech ->
        case Map.fetch(config, Atom.to_string(key)) do
          {:ok, value} -> Map.put(speech, key, value)
          :error -> speech
        end
      end)
      |> Map.put(:max_bytes, Map.get(config, "max_bytes", runtime[:max_bytes] || @max_bytes))

    %{adapter: DeepInfra, provider: "deepinfra", request: request, config: speech}
  end

  defp prepare_speech(request, config, runtime, %{type: "vydra_speech"} = provider) do
    raw =
      Enum.reduce([{"model", :model}, {"voiceId", :voice_id}], %{}, fn {source, host}, raw ->
        case saved_setting(provider.config || %{}, source, host) do
          {:ok, value} -> Map.put(raw, source, value)
          :error -> raw
        end
      end)
      |> Map.put("apiKey", runtime[:api_key])
      |> Map.put("baseUrl", runtime[:base_url])

    saved = Vydra.resolve_config(%{"providers" => %{"vydra" => raw}})

    speech =
      Enum.reduce(@vydra_keys, saved, fn key, speech ->
        case Map.fetch(config, Atom.to_string(key)) do
          {:ok, value} -> Map.put(speech, key, value)
          :error -> speech
        end
      end)
      |> Map.put(:max_bytes, Map.get(config, "max_bytes", runtime[:max_bytes] || @max_bytes))

    # Configuration preflight is pure but uses the same required per-stage
    # duration shape as synthesis. Invocation requests already contain theirs.
    request = Map.put_new(request, :timeout_ms, Map.get(config, "timeout_ms", @timeout))
    %{adapter: Vydra, provider: "vydra", request: request, config: speech}
  end

  defp prepare_speech(request, config, _runtime, %{type: "clawrouter_speech"} = provider) do
    case Providers.clawrouter_speech_config(provider.id, config) do
      {:ok, %{provider_id: id, provider_name: name} = prepared}
      when id == provider.id and name == provider.name ->
        %{
          adapter: ClawRouter,
          provider: "clawrouter",
          request: Map.put_new(request, :timeout_ms, prepared.timeout_ms),
          config: prepared.config
        }

      _ ->
        %{adapter: ClawRouter, provider: "clawrouter", request: request, config: %{}}
    end
  end

  defp prepare_speech(request, config, _runtime, %{type: "xiaomi_speech"} = provider) do
    case Providers.xiaomi_speech_config(provider.id, config) do
      {:ok, %{provider_id: id, provider_name: name} = prepared}
      when id == provider.id and name == provider.name ->
        %{
          adapter: Xiaomi,
          provider: "xiaomi",
          request: Map.put_new(request, :timeout_ms, prepared.timeout_ms),
          config: prepared.config
        }

      _ ->
        %{adapter: Xiaomi, provider: "xiaomi", request: request, config: %{}}
    end
  end

  defp prepare_speech(request, config, _runtime, %{type: "azure_speech"} = provider) do
    case Providers.azure_speech_config(provider.id, config) do
      {:ok, prepared} ->
        %{
          adapter: Azure,
          provider: "azure",
          request: Map.put_new(request, :timeout_ms, prepared.timeout_ms),
          config: prepared.config
        }

      _ ->
        %{adapter: Azure, provider: "azure", request: request, config: %{}}
    end
  end

  defp prepare_speech(request, config, _runtime, %{type: "google_speech"} = provider) do
    case Providers.google_speech_config(provider.id, config) do
      {:ok, %{provider_id: id, provider_name: name} = prepared}
      when id == provider.id and name == provider.name ->
        %{
          adapter: Google,
          provider: "google",
          request: Map.put_new(request, :timeout_ms, prepared.timeout_ms),
          config: prepared.config
        }

      _ ->
        %{adapter: Google, provider: "google", request: request, config: %{}}
    end
  end

  defp prepare_speech(request, config, _runtime, %{type: "fish_audio_speech"} = provider) do
    case Providers.fish_audio_config(provider.id, config) do
      {:ok, %{provider_id: id, provider_name: name} = prepared}
      when id == provider.id and name == provider.name ->
        %{
          adapter: FishAudio,
          provider: "fish-audio",
          request: Map.put_new(request, :timeout_ms, prepared.timeout_ms),
          config: prepared.config
        }

      _ ->
        %{adapter: FishAudio, provider: "fish-audio", request: request, config: %{}}
    end
  end

  defp prepare_speech(request, config, _runtime, %{type: "openai_speech"} = provider) do
    case Providers.openai_speech_config(provider.id, config) do
      {:ok, prepared} ->
        %{adapter: OpenAI, provider: "openai", request: request, config: prepared.config}

      _ ->
        %{adapter: OpenAI, provider: "openai", request: request, config: %{}}
    end
  end

  defp prepare_speech(request, config, runtime, _provider),
    do: %{
      adapter: OpenAI,
      provider: "openai",
      request: request,
      config: speech_config(config, runtime)
    }

  defp saved_setting(config, source, host) do
    Enum.reduce_while([source, Atom.to_string(host), host], :error, fn key, :error ->
      case Map.fetch(config, key) do
        {:ok, _} = found -> {:halt, found}
        :error -> {:cont, :error}
      end
    end)
  end

  # Vydra's format is determined by the downloaded response, so preflight
  # validates only the wire intent instead of guessing a media format.
  defp build_speech(%{adapter: Vydra} = speech),
    do: Vydra.build_request(speech.request, speech.config)

  defp build_speech(speech) do
    with {:ok, built} <- speech.adapter.build_request(speech.request, speech.config),
         format = Map.get(built, :media_format, built.output_format),
         true <-
           format in ~w(mp3 opus wav) or
             (speech.adapter == OpenRouter and format == "pcm") or
             (speech.adapter == DeepInfra and format in ~w(flac pcm)) or
             (speech.adapter == ClawRouter and format in ~w(mp3 opus aac flac wav pcm)) or
             (speech.adapter == Azure and format in ~w(mp3 ogg webm wav pcm amr audio)) do
      {:ok, built}
    else
      _ -> unavailable()
    end
  end

  defp execute_ready(input, speech, context, operation) do
    with {:ok, native} <- live_deadline(operation) do
      request =
        if speech.adapter in [
             OpenAI,
             ElevenLabs,
             Inworld,
             Vydra,
             FishAudio,
             Google,
             Azure,
             Xiaomi,
             ClawRouter
           ] do
          # Each HTTP operation gets T, clipped by this live native deadline.
          # Fish has one operation; Vydra and Google reserve two stages.
          speech.request
          |> Map.put(:timeout_ms, input.timeout)
          |> Map.put(:deadline_ms, native.deadline_ms)
        else
          Map.put(speech.request, :timeout_ms, min(input.timeout, native.remaining_ms))
        end

      with {:ok, request} <- prepare_invocation(speech, request) do
        synthesize_ready(input, %{speech | request: request}, context, operation)
      end
    end
  end

  # Prompt preparation is consumer-owned and occurs once in the actual effect.
  # Classification and configuration preflight never wrap the original text.
  defp prepare_invocation(%{adapter: Google, config: config}, request) do
    case Google.prepare_synthesis(%{text: request.text, provider_config: config}) do
      {:ok, nil} -> {:ok, request}
      {:ok, %{text: text}} -> {:ok, Map.put(request, :text, text)}
      _ -> unavailable()
    end
  end

  defp prepare_invocation(_speech, request), do: {:ok, request}

  defp synthesize_ready(input, speech, context, operation) do
    case speech.adapter.synthesize(speech.request, speech.config) do
      {:ok, response} ->
        with {:ok, native} <- live_deadline(operation),
             {:ok, media} <-
               Media.put_audio(
                 response.audio,
                 Map.get(response, :media_format, response.output_format),
                 root: context.media_root,
                 max_bytes: speech.config.max_bytes,
                 deadline: native.deadline_ms
               ),
             {:ok, _} <- live_deadline(operation),
             {:ok, delivery} <-
               MediaDelivery.publish(media, context.identity.session_id, operation,
                 root: context.media_root,
                 max_bytes: speech.config.max_bytes
               ) do
          output(input, media, delivery, speech.provider, response)
        else
          _ -> uncertain()
        end

      {:error, reason} when reason in [:timeout, :transport] ->
        uncertain()

      _ ->
        failure(:execution_failure, "TTS synthesis did not complete")
    end
  end

  defp live_deadline(operation) do
    with accessor when is_function(accessor, 0) <- operation.backend_context[:effect_deadline],
         {:ok, %{remaining_ms: remaining, deadline_ms: deadline, paused: false} = native} <-
           accessor.(),
         true <- is_integer(remaining) and remaining > 0 and is_integer(deadline) do
      {:ok, native}
    else
      _ -> uncertain()
    end
  end

  defp output(input, media, delivery, provider, response) do
    # Preserve the pinned tts-tool.ts transcript shaping before durable history.
    transcript =
      input.text
      |> String.replace("[[", "[\u2060[")
      |> String.replace(~r/^(\s*)(MEDIA:)/imu, "\\1\u2060\\2")
      |> String.replace(~r/^([ \t]*)(`)(`{2,})/mu, "\\1\\2\u2060\\3")

    details = %{
      audioPath: media["uri"],
      provider: provider,
      media: %{mediaUrl: media["uri"], trustedLocalMedia: true},
      mediaDescriptor: media,
      mediaDelivery: delivery
    }

    details =
      if provider in ["azure", "xiaomi", "clawrouter"] do
        Map.merge(details, %{
          outputFormat: response.output_format,
          fileExtension: response.file_extension,
          voiceCompatible: response.voice_compatible
        })
      else
        details
      end

    details =
      if input.supplied_timeout,
        do: Map.put(details, :timeoutMs, input.supplied_timeout),
        else: details

    result = %{content: [%{type: "text", text: "(spoken) " <> transcript}], details: details}

    case ToolEffects.validate_output(%{payload: result}) do
      {:ok, _} -> {:ok, result}
      _ -> failure(:budget_exceeded, "TTS result exceeds the native result budget")
    end
  end

  defp fingerprint(agent, config, provider, root),
    do: digest({agent.id, agent.name, agent.tools, config, timing(config, provider), root})

  defp provider_fingerprint(provider),
    do:
      digest({
        Map.take(provider, [:id, :name, :type, :enabled, :base_url, :config, :credential_id]),
        Providers.authentication_generation(provider)
      })

  defp digest(value),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
      |> Base.encode16(case: :lower)

  defp descriptor(context) do
    %{
      tool_name: @name,
      tool_revision: 1,
      description:
        "Convert text to spoken audio with the explicitly configured speech provider and create a durable local audio file. Only use for explicit speech or TTS intent. Audio delivery and playback are separate.",
      schema: schema(),
      safety: %{read_only: false, retry_safe: false, parallel_safe: false},
      codex_exposure: :direct_model_only,
      backend: __MODULE__,
      backend_context: context
    }
  end

  defp schema do
    %{
      "type" => "object",
      "properties" => %{
        "text" => %{"type" => "string", "description" => "Text to speak."},
        "channel" => %{
          "type" => "string",
          "description" =>
            "Channel id; output-format hint. Currently omit or leave empty for a local audio file."
        },
        "timeoutMs" => %{
          "type" => "integer",
          "description" => "Provider timeout ms.",
          "minimum" => 1
        }
      },
      "required" => ["text"],
      "additionalProperties" => false
    }
  end

  defp unavailable,
    do:
      failure(
        :unsupported_capability,
        "TTS requires an enabled Agent and explicit available speech provider"
      )

  defp uncertain,
    do:
      failure(
        :unknown_outcome,
        "TTS synthesis or publication could not be confirmed; it was not replayed"
      )

  defp failure(class, message), do: {:error, Error.new(class, message)}
end
