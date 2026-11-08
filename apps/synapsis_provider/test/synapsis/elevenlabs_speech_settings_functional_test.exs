defmodule Synapsis.ElevenLabsSpeechSettingsFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Config.Store
  alias Synapsis.Provider.{Registry, Speech.ElevenLabs}
  alias Synapsis.{Credentials, ProviderConfig, Providers}

  @defaults %{
    stability: 0.5,
    similarity_boost: 0.75,
    style: 0,
    use_speaker_boost: true,
    speed: 1
  }

  test "existing editable ElevenLabs identity remains explicit TTS" do
    assert "elevenlabs" in ProviderConfig.valid_types()

    assert %{
             name: "elevenlabs",
             label: "ElevenLabs",
             type: "elevenlabs",
             base_url: "https://api.elevenlabs.io",
             base_url_editable: true,
             discover_models: false
           } = Enum.find(Providers.preset_providers(), &(&1.name == "elevenlabs"))

    assert Providers.default_base_url("elevenlabs") == "https://api.elevenlabs.io"
    assert Providers.speech_capabilities(%{type: "elevenlabs"}) == [:tts]
    assert Providers.speech_only?(%{type: "elevenlabs"})
  end

  test "current UUID rename root referenced credential and advanced settings survive preparation without synthesis" do
    tracer = trace_preparation()

    settings = %{
      "voiceId" => " SavedVoice123456 ",
      "modelId" => " saved_custom_model ",
      "seed" => 37,
      "applyTextNormalization" => " AUTO ",
      "languageCode" => " EN ",
      "voiceSettings" => %{
        "stability" => 0.4,
        "similarityBoost" => 0.65,
        "style" => 0.2,
        "useSpeakerBoost" => false,
        "speed" => 1.15
      },
      "apiKey" => "saved-setting-is-not-current-credential",
      "baseUrl" => "https://saved-setting.example/ignored",
      "timeoutMs" => 60_000,
      "timeout_ms" => 75_000,
      "max_bytes" => 65_536,
      "operator_note" => "Retain complete advanced settings",
      "advanced" => %{"custom" => ["one", "two"]}
    }

    {provider, credential} = saved(settings)
    id = provider.id
    assert {:ok, ^id} = Ecto.UUID.cast(id)
    assert {:ok, prepared} = Providers.elevenlabs_speech_config(id, %{})

    assert prepared == %{
             provider_id: id,
             provider_name: provider.name,
             timeout_ms: 30_000,
             config: %{
               api_key: "initial-elevenlabs-speech-fixture",
               base_url: "https://Saved.Example/custom",
               voice_id: "SavedVoice123456",
               model_id: "saved_custom_model",
               seed: 37,
               apply_text_normalization: "AUTO",
               language_code: "EN",
               voice_settings: %{
                 stability: 0.4,
                 similarity_boost: 0.65,
                 style: 0.2,
                 use_speaker_boost: false,
                 speed: 1.15
               },
               max_bytes: 65_536
             }
           }

    current_name = "current-elevenlabs-#{Ecto.UUID.generate()}"
    root = "https://Current.Example/tenant///"

    current_settings =
      settings |> Map.put("voiceId", " CurrentVoice12345 ") |> Map.put("seed", 73)

    assert {:ok, _} =
             Providers.update(id, %{name: current_name, base_url: root, config: current_settings})

    assert {:ok, _} =
             Credentials.update(credential.id, %{key: "current-elevenlabs-speech-fixture"})

    assert :ok = Store.reload(:provider)
    assert {:ok, reopened} = Providers.get(id)
    assert reopened.name == current_name
    assert reopened.credential_id == credential.id
    assert reopened.api_key_encrypted == "current-elevenlabs-speech-fixture"
    assert reopened.config == current_settings
    assert {:ok, by_name} = Providers.get_by_name(current_name)
    assert by_name.id == id
    assert {:ok, current} = Providers.elevenlabs_speech_config(id, %{})

    assert current == %{
             prepared
             | provider_name: current_name,
               config: %{
                 prepared.config
                 | api_key: "current-elevenlabs-speech-fixture",
                   base_url: "https://Current.Example/tenant",
                   voice_id: "CurrentVoice12345",
                   seed: 73
               }
           }

    assert {:ok, runtime} = Providers.runtime_config(current_name)
    assert runtime.provider_id == id
    assert runtime.provider_name == current_name
    assert runtime.api_key == "current-elevenlabs-speech-fixture"
    assert runtime.base_url == root
    assert {:ok, ^runtime} = Registry.get(current_name)

    assert {:ok, overlaid} =
             Providers.elevenlabs_speech_config(id, %{
               "voice_id" => " AgentVoice123456 ",
               "model_id" => " eleven_turbo_v2 ",
               "seed" => 83,
               "apply_text_normalization" => " ON ",
               "language_code" => " DE ",
               "voice_settings" => %{"stability" => 0.6, "speed" => 1.4},
               "timeout_ms" => 45_000,
               "max_bytes" => 131_072
             })

    assert overlaid == %{
             current
             | timeout_ms: 45_000,
               config: %{
                 current.config
                 | voice_id: "AgentVoice123456",
                   model_id: "eleven_flash_v2",
                   seed: 83,
                   apply_text_normalization: "on",
                   language_code: "de",
                   voice_settings: %{
                     stability: 0.6,
                     similarity_boost: 0.65,
                     style: 0.2,
                     use_speaker_boost: false,
                     speed: 1.4
                   },
                   max_bytes: 131_072
               }
           }

    assert {:ok, built} =
             ElevenLabs.build_request(
               %{text: "  Saved UUID line.\n亲切  ", target: :audio_file, timeout_ms: 12_345},
               overlaid.config
             )

    assert built.url ==
             "https://Current.Example/tenant/v1/text-to-speech/AgentVoice123456?output_format=mp3_44100_128"

    assert built.timeout_ms === 12_345

    assert built.body == %{
             "text" => "  Saved UUID line.\n亲切  ",
             "model_id" => "eleven_flash_v2",
             "seed" => 83,
             "apply_text_normalization" => "on",
             "language_code" => "de",
             "voice_settings" => %{
               "stability" => 0.6,
               "similarity_boost" => 0.65,
               "style" => 0.2,
               "use_speaker_boost" => false,
               "speed" => 1.4
             }
           }

    assert_saved(id, current_name, root, credential.id, current_settings)
    assert :ok = Store.reload(:provider)
    assert_saved(id, current_name, root, credential.id, current_settings)
    assert_no_synthesis(tracer)
  end

  for {name, settings} <- [
        {"camel",
         %{
           "voiceId" => " SavedVoice123456 ",
           "modelId" => " eleven_turbo_v2_5 ",
           "applyTextNormalization" => " AUTO ",
           "languageCode" => " FR ",
           "voiceSettings" => %{
             "similarityBoost" => 0.8,
             "useSpeakerBoost" => false,
             "style" => 0.3
           }
         }},
        {"snake",
         %{
           "voice_id" => " SavedVoice123456 ",
           "model_id" => " eleven_turbo_v2_5 ",
           "apply_text_normalization" => " AUTO ",
           "language_code" => " FR ",
           "voice_settings" => %{
             "similarity_boost" => 0.8,
             "use_speaker_boost" => false,
             "style" => 0.3
           }
         }}
      ] do
    @settings settings
    test "saved #{name} fields normalize before partial Agent voice settings merge" do
      tracer = trace_preparation()
      {provider, credential} = saved(@settings)
      assert {:ok, prepared} = Providers.elevenlabs_speech_config(provider.id, %{})

      assert prepared.config == %{
               api_key: "initial-elevenlabs-speech-fixture",
               base_url: "https://Saved.Example/custom",
               voice_id: "SavedVoice123456",
               model_id: "eleven_flash_v2_5",
               apply_text_normalization: "AUTO",
               language_code: "FR",
               voice_settings: %{
                 @defaults
                 | similarity_boost: 0.8,
                   use_speaker_boost: false,
                   style: 0.3
               },
               max_bytes: 16 * 1024 * 1024
             }

      assert prepared.timeout_ms == 30_000

      assert {:ok, overlaid} =
               Providers.elevenlabs_speech_config(provider.id, %{
                 voice_id: " OverlayVoice12345 ",
                 language_code: " JA ",
                 voice_settings: %{speed: 1.3, stability: 0.6}
               })

      assert overlaid == %{
               prepared
               | config: %{
                   prepared.config
                   | voice_id: "OverlayVoice12345",
                     language_code: "ja",
                     voice_settings: %{
                       stability: 0.6,
                       similarity_boost: 0.8,
                       style: 0.3,
                       use_speaker_boost: false,
                       speed: 1.3
                     }
                 }
             }

      assert_saved(provider.id, provider.name, provider.base_url, credential.id, @settings)
      assert_no_synthesis(tracer)
    end
  end

  for {name, root, normalized} <- [
        {"official", " https://api.elevenlabs.io/// ", "https://api.elevenlabs.io"},
        {"custom", " https://speech.example.test/tenant/// ",
         "https://speech.example.test/tenant"}
      ] do
    @root root
    @normalized normalized
    test "saved #{name} root is trimmed and request alone adds v1" do
      tracer = trace_preparation()
      settings = %{"voice_id" => "SavedVoice123456", "model_id" => "eleven_multilingual_v2"}
      {provider, credential} = saved(settings)
      assert {:ok, stored} = Store.get(:provider, provider.id)

      assert {:ok, _} =
               Store.replace_existing(:provider, provider.id, Map.put(stored, "base_url", @root))

      assert :ok = Store.reload(:provider)
      assert {:ok, prepared} = Providers.elevenlabs_speech_config(provider.id, %{})
      assert prepared.config.base_url == @normalized
      assert prepared.provider_id == provider.id
      assert prepared.timeout_ms == 30_000

      assert {:ok, built} =
               ElevenLabs.build_request(
                 %{text: "Root convention.", target: :audio_file, timeout_ms: 12_345},
                 prepared.config
               )

      assert built.url ==
               @normalized <> "/v1/text-to-speech/SavedVoice123456?output_format=mp3_44100_128"

      assert_saved(provider.id, provider.name, @root, credential.id, settings)
      assert_no_synthesis(tracer)
    end
  end

  test "current UUID preparation uses displayed canonical settings with retained camel aliases" do
    tracer = trace_preparation()

    settings = %{
      "voice_id" => " ChosenVoice1234567 ",
      "voiceId" => " CamelVoice123456 ",
      "model_id" => " tenant-current-model ",
      "modelId" => " eleven_turbo_v2_5 ",
      "seed" => 91,
      "apply_text_normalization" => " ON ",
      "applyTextNormalization" => " AUTO ",
      "language_code" => " FR ",
      "languageCode" => " EN ",
      "voice_settings" => %{
        "stability" => 0.6,
        "similarity_boost" => 0.8,
        "style" => 0.2,
        "use_speaker_boost" => false,
        "speed" => 1.45,
        "current_unknown" => %{"preserve" => [1, 2]}
      },
      "voiceSettings" => %{"futureField" => "keep source alias raw"},
      "max_bytes" => 65_536,
      "current_fixture" => ["keep", "all"]
    }

    {provider, credential} = saved(settings)
    id = provider.id
    assert {:ok, ^id} = Ecto.UUID.cast(id)
    assert :ok = Store.reload(:provider)
    raw_toml = File.read!(Store.file_path(:provider))

    assert {:ok, prepared} = Providers.elevenlabs_speech_config(id, %{})

    assert prepared == %{
             provider_id: id,
             provider_name: provider.name,
             timeout_ms: 30_000,
             config: %{
               api_key: "initial-elevenlabs-speech-fixture",
               base_url: "https://Saved.Example/custom",
               voice_id: "ChosenVoice1234567",
               model_id: "tenant-current-model",
               seed: 91,
               apply_text_normalization: "ON",
               language_code: "FR",
               voice_settings: %{
                 stability: 0.6,
                 similarity_boost: 0.8,
                 style: 0.2,
                 use_speaker_boost: false,
                 speed: 1.45
               },
               max_bytes: 65_536
             }
           }

    assert {:ok, overlaid} =
             Providers.elevenlabs_speech_config(id, %{
               "voice_settings" => %{"stability" => 0.7, "speed" => 1.3}
             })

    assert overlaid == %{
             provider_id: id,
             provider_name: provider.name,
             timeout_ms: 30_000,
             config: %{
               api_key: "initial-elevenlabs-speech-fixture",
               base_url: "https://Saved.Example/custom",
               voice_id: "ChosenVoice1234567",
               model_id: "tenant-current-model",
               seed: 91,
               apply_text_normalization: "ON",
               language_code: "FR",
               voice_settings: %{
                 stability: 0.7,
                 similarity_boost: 0.8,
                 style: 0.2,
                 use_speaker_boost: false,
                 speed: 1.3
               },
               max_bytes: 65_536
             }
           }

    # Host alias precedence does not broaden the nested source resolver contract.
    assert ElevenLabs.resolve_config(%{"providers" => %{"elevenlabs" => settings}}) == %{
             base_url: "https://api.elevenlabs.io",
             voice_id: "CamelVoice123456",
             model_id: "eleven_flash_v2_5",
             seed: 91,
             apply_text_normalization: "AUTO",
             language_code: "EN",
             voice_settings: %{
               stability: 0.5,
               similarity_boost: 0.75,
               style: 0,
               use_speaker_boost: true,
               speed: 1
             }
           }

    assert_saved(id, provider.name, provider.base_url, credential.id, settings)
    assert File.read!(Store.file_path(:provider)) == raw_toml
    assert :ok = Store.reload(:provider)
    assert_saved(id, provider.name, provider.base_url, credential.id, settings)
    assert File.read!(Store.file_path(:provider)) == raw_toml
    assert_no_synthesis(tracer)
  end

  test "current UUID connection root wins over saved speech and explicit Agent root text" do
    tracer = trace_preparation()

    settings = %{
      "voice_id" => "SavedVoice123456",
      "model_id" => "eleven_multilingual_v2",
      "base_url" => "https://Saved.Snake.Example/options///",
      "baseUrl" => "https://Saved.Camel.Example/options///"
    }

    {provider, credential} = saved(settings)
    id = provider.id
    current_name = "current-root-elevenlabs-#{Ecto.UUID.generate()}"
    root = "https://Current.Example/tenant///"

    assert {:ok, _} = Providers.update(id, %{name: current_name, base_url: root})

    assert {:ok, _} =
             Credentials.update(credential.id, %{key: "current-elevenlabs-speech-fixture"})

    assert :ok = Store.reload(:provider)
    assert {:ok, reopened} = Providers.get(id)
    assert reopened.id == id
    assert reopened.name == current_name
    assert reopened.base_url == root
    assert reopened.credential_id == credential.id
    assert reopened.api_key_encrypted == "current-elevenlabs-speech-fixture"
    raw_toml = File.read!(Store.file_path(:provider))

    assert {:ok, prepared} =
             Providers.elevenlabs_speech_config(id, %{
               "base_url" => "https://Agent.Snake.Example/options///",
               "baseUrl" => "https://Agent.Camel.Example/options///",
               "seed" => 47
             })

    assert prepared == %{
             provider_id: id,
             provider_name: current_name,
             timeout_ms: 30_000,
             config: %{
               api_key: "current-elevenlabs-speech-fixture",
               base_url: "https://Current.Example/tenant",
               voice_id: "SavedVoice123456",
               model_id: "eleven_multilingual_v2",
               seed: 47,
               voice_settings: %{
                 stability: 0.5,
                 similarity_boost: 0.75,
                 style: 0,
                 use_speaker_boost: true,
                 speed: 1
               },
               max_bytes: 16 * 1024 * 1024
             }
           }

    assert {:ok, built} =
             ElevenLabs.build_request(
               %{text: "Current connection root.", target: :audio_file, timeout_ms: 12_345},
               prepared.config
             )

    assert built.url ==
             "https://Current.Example/tenant/v1/text-to-speech/SavedVoice123456?output_format=mp3_44100_128"

    assert {"xi-api-key", "current-elevenlabs-speech-fixture"} in built.headers
    assert_saved(id, current_name, root, credential.id, settings)
    assert File.read!(Store.file_path(:provider)) == raw_toml
    assert :ok = Store.reload(:provider)
    assert_saved(id, current_name, root, credential.id, settings)
    assert File.read!(Store.file_path(:provider)) == raw_toml
    assert_no_synthesis(tracer)
  end

  defp saved(settings) do
    assert {:ok, credential} =
             Credentials.create(%{
               name: "elevenlabs-credential-#{Ecto.UUID.generate()}",
               key: "initial-elevenlabs-speech-fixture"
             })

    on_exit(fn -> Credentials.delete(credential.id) end)

    assert {:ok, provider} =
             Providers.create(%{
               name: "my-elevenlabs-#{Ecto.UUID.generate()}",
               type: "elevenlabs",
               preset: "elevenlabs",
               base_url: "https://Saved.Example/custom///",
               credential_id: credential.id,
               config: settings
             })

    on_exit(fn -> Providers.delete(provider.id) end)
    {provider, credential}
  end

  defp assert_saved(id, name, root, credential_id, config) do
    assert {:ok, toml} = Toml.decode(File.read!(Store.file_path(:provider)))
    persisted = Enum.find(toml["providers"], &(&1["id"] == id))

    assert Map.take(persisted, ~w(id name type preset base_url credential_id config)) == %{
             "id" => id,
             "name" => name,
             "type" => "elevenlabs",
             "preset" => "elevenlabs",
             "base_url" => root,
             "credential_id" => credential_id,
             "config" => config
           }

    assert {:ok, saved} = Providers.get(id)
    assert saved.config == config
  end

  defp trace_preparation do
    Code.ensure_loaded!(ElevenLabs)
    functions = [:synthesize, :synthesize_telephony, :stream_synthesize, :list_voices]
    tracer = spawn(fn -> trace_loop([]) end)

    for function <- functions,
        do: :erlang.trace_pattern({ElevenLabs, function, 2}, true, [:local])

    caller = self()
    :erlang.trace(caller, true, [:call, :set_on_spawn, {:tracer, tracer}])

    on_exit(fn ->
      if Process.alive?(caller), do: :erlang.trace(caller, false, [:all])

      for function <- functions,
          do: :erlang.trace_pattern({ElevenLabs, function, 2}, false, [:local])

      send(tracer, :stop)
    end)

    tracer
  end

  defp assert_no_synthesis(tracer) do
    barrier = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^barrier}, 5_000
    token = make_ref()
    send(tracer, {:snapshot, self(), token})
    assert_receive {:prepared_calls, ^token, []}, 5_000
  end

  defp trace_loop(calls) do
    receive do
      {:trace, _pid, :call, {ElevenLabs, function, _args}} ->
        trace_loop([function | calls])

      {:snapshot, caller, token} ->
        send(caller, {:prepared_calls, token, Enum.reverse(calls)})
        trace_loop(calls)

      :stop ->
        :ok
    end
  end
end
