defmodule Synapsis.OpenAISpeechSettingsFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Config.Store
  alias Synapsis.Provider.{Registry, Speech.OpenAI}
  alias Synapsis.{Credentials, ProviderConfig, Providers}

  test "existing formal editable OpenAI Speech preset retains TTS and STT" do
    assert "openai_speech" in ProviderConfig.valid_types()

    assert %{
             name: "openai-speech",
             label: "OpenAI Speech",
             type: "openai_speech",
             base_url: "https://api.openai.com",
             base_url_editable: true,
             discover_models: false
           } = Enum.find(Providers.preset_providers(), &(&1.name == "openai-speech"))

    assert Providers.default_base_url("openai_speech") == "https://api.openai.com"
    assert Providers.speech_capabilities(%{type: "openai_speech"}) == [:tts, :stt]
    assert Providers.speech_only?(%{type: "openai_speech"})
  end

  test "current saved UUID name route and referenced credential retain all advanced TOML" do
    settings = %{
      "model" => " studio-tts ",
      "voice" => " Studio Voice ",
      "responseFormat" => " OPUS ",
      "speed" => 1.35,
      "instructions" => "  Calm saved reading.  ",
      "extraBody" => %{"language" => "ja", "seed" => 17},
      "extra_body" => %{"language" => "en", "seed" => 23},
      "timeoutMs" => 60_000,
      "timeout_ms" => 75_000,
      "max_bytes" => 65_536,
      "operator_note" => "Keep the complete advanced settings",
      "advanced" => %{"custom" => ["one", "two"]}
    }

    {provider, credential} = saved(settings)
    id = provider.id
    assert {:ok, ^id} = Ecto.UUID.cast(id)
    assert {:ok, by_name} = Providers.get_by_name(provider.name)
    assert by_name.id == id
    assert by_name.credential_id == credential.id
    assert {:ok, prepared} = Providers.openai_speech_config(id)

    assert prepared == %{
             provider_id: id,
             provider_name: provider.name,
             timeout_ms: 30_000,
             config: %{
               api_key: "initial-openai-speech-fixture",
               base_url: "https://Saved.Example/custom/v1",
               model: "studio-tts",
               voice: "Studio Voice",
               response_format: "opus",
               speed: 1.35,
               instructions: "Calm saved reading.",
               extra_body: %{"language" => "ja", "seed" => 17},
               max_bytes: 65_536
             }
           }

    assert {:ok, built} =
             OpenAI.build_request(
               %{text: "Saved speech.", target: :audio_file, timeout_ms: 21_123.75},
               prepared.config
             )

    assert built.url == "https://Saved.Example/custom/v1/audio/speech"
    assert built.timeout_ms === 21_123.75

    endpoint = "https://Current.Example/tenant/v1///"
    current_name = "current-openai-speech-#{Ecto.UUID.generate()}"

    updated_settings =
      settings
      |> Map.put("voice", " Current Voice ")
      |> Map.put("instructions", " Current saved direction. ")

    assert {:ok, _} =
             Providers.update(id, %{
               name: current_name,
               base_url: endpoint,
               config: updated_settings
             })

    assert {:ok, _} = Credentials.update(credential.id, %{key: "current-openai-speech-fixture"})
    assert {:ok, toml} = Toml.decode(File.read!(Store.file_path(:provider)))
    persisted = Enum.find(toml["providers"], &(&1["id"] == id))

    assert Map.take(persisted, ~w(id name type preset base_url credential_id config)) == %{
             "id" => id,
             "name" => current_name,
             "type" => "openai_speech",
             "preset" => "openai-speech",
             "base_url" => endpoint,
             "credential_id" => credential.id,
             "config" => updated_settings
           }

    assert :ok = Store.reload(:provider)
    assert {:ok, reopened} = Providers.get(id)
    assert reopened.name == current_name
    assert reopened.config == updated_settings
    assert reopened.base_url == endpoint
    assert reopened.credential_id == credential.id
    assert reopened.api_key_encrypted == "current-openai-speech-fixture"
    assert {:ok, current} = Providers.openai_speech_config(id)

    assert current == %{
             prepared
             | provider_name: current_name,
               config: %{
                 prepared.config
                 | api_key: "current-openai-speech-fixture",
                   base_url: "https://Current.Example/tenant/v1",
                   voice: "Current Voice",
                   instructions: "Current saved direction."
               }
           }

    assert {:ok, runtime} = Providers.runtime_config(current_name)
    assert runtime.provider_id == id
    assert runtime.provider_name == current_name
    assert runtime.base_url == endpoint
    assert runtime.api_key == "current-openai-speech-fixture"
    assert {:ok, ^runtime} = Registry.get(current_name)

    assert {:ok, overlaid} =
             Providers.openai_speech_config(id, %{
               "model" => " agent-studio-tts ",
               "voice" => " Agent Voice ",
               "response_format" => " WAV ",
               "speed" => 1.65,
               "instructions" => " Agent direction. ",
               "extra_body" => %{"language" => "fr", "seed" => 31},
               "timeout_ms" => 45_000,
               "max_bytes" => 131_072
             })

    assert overlaid == %{
             current
             | timeout_ms: 45_000,
               config: %{
                 current.config
                 | model: "agent-studio-tts",
                   voice: "Agent Voice",
                   response_format: "wav",
                   speed: 1.65,
                   instructions: "Agent direction.",
                   extra_body: %{"language" => "fr", "seed" => 31},
                   max_bytes: 131_072
               }
           }

    assert {:ok, built} =
             OpenAI.build_request(
               %{text: "Agent overlay.", target: :audio_file, timeout_ms: 75_000},
               overlaid.config
             )

    assert built.url == "https://Current.Example/tenant/v1/audio/speech"
    assert built.timeout_ms == 75_000

    assert built.body == %{
             "model" => "agent-studio-tts",
             "input" => "Agent overlay.",
             "voice" => "Agent Voice",
             "response_format" => "wav",
             "speed" => 1.65,
             "instructions" => "Agent direction.",
             "language" => "fr",
             "seed" => 31
           }

    assert_saved(id, current_name, endpoint, credential.id, updated_settings)
    assert :ok = Store.reload(:provider)
    assert_saved(id, current_name, endpoint, credential.id, updated_settings)
  end

  for {id, settings} <- [
        {"camel",
         %{
           "model" => " tts-1 ",
           "voice" => " echo ",
           "responseFormat" => " OPUS ",
           "extraBody" => %{"language" => "ja"},
           "extra_body" => %{"language" => "en"}
         }},
        {"snake",
         %{
           "model" => " tts-1 ",
           "voice" => " echo ",
           "response_format" => " OPUS ",
           "extra_body" => %{"language" => "ja"}
         }}
      ] do
    @settings settings
    test "saved #{id} fields normalize before canonical partial Agent overlay" do
      settings = Map.merge(@settings, %{"instructions" => " Saved direction. ", "speed" => 1.4})
      {provider, credential} = saved(settings)
      assert {:ok, prepared} = Providers.openai_speech_config(provider.id)

      assert prepared.config == %{
               api_key: "initial-openai-speech-fixture",
               base_url: "https://Saved.Example/custom/v1",
               model: "tts-1",
               voice: "echo",
               response_format: "opus",
               extra_body: %{"language" => "ja"},
               instructions: "Saved direction.",
               speed: 1.4,
               max_bytes: 16 * 1024 * 1024
             }

      assert prepared.timeout_ms == 30_000

      assert {:ok, overlaid} =
               Providers.openai_speech_config(provider.id, %{
                 "voice" => " nova ",
                 "response_format" => " MP3 ",
                 "extra_body" => %{"language" => "de"}
               })

      assert overlaid == %{
               prepared
               | config: %{
                   prepared.config
                   | voice: "nova",
                     response_format: "mp3",
                     extra_body: %{"language" => "de"}
                 }
             }

      assert_saved(provider.id, provider.name, provider.base_url, credential.id, settings)
    end
  end

  for {id, root, expected} <- [
        {"official-root", " https://api.openai.com/// ", "https://api.openai.com/v1"},
        {"official-v1", " https://api.openai.com/v1/// ", "https://api.openai.com/v1"},
        {"custom-prefix", " https://speech.example.test/tenant/// ",
         "https://speech.example.test/tenant/v1"},
        {"groq-prefix", " https://api.groq.com/openai/// ", "https://api.groq.com/openai/v1"}
      ] do
    @root root
    @expected expected
    test "saved application API-root normalization #{id} is distinct from source resolution" do
      settings = %{"model" => "gpt-4o-mini-tts", "voice" => "coral"}
      {provider, credential} = saved(settings)
      # ProviderConfig validates CRUD URLs before preparation. Existing TOML may
      # contain surrounding whitespace; install that positive read fixture via
      # the owning Config.Store API, preserving the complete saved record.
      assert {:ok, stored} = Store.get(:provider, provider.id)

      assert {:ok, _} =
               Store.replace_existing(:provider, provider.id, Map.put(stored, "base_url", @root))

      assert :ok = Store.reload(:provider)
      assert {:ok, prepared} = Providers.openai_speech_config(provider.id)
      assert prepared.config.base_url == @expected
      assert prepared.provider_id == provider.id
      assert prepared.provider_name == provider.name
      assert prepared.timeout_ms == 30_000

      assert {:ok, built} =
               OpenAI.build_request(
                 %{text: "Root convention.", target: :audio_file},
                 prepared.config
               )

      assert built.url == @expected <> "/audio/speech"
      assert_saved(provider.id, provider.name, @root, credential.id, settings)
    end
  end

  test "current same-provider UUID route and canonical Agent settings produce exact positive HTTP" do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)

    settings = %{
      "model" => "saved-studio-tts",
      "voice" => "Saved Voice",
      "responseFormat" => "opus",
      "speed" => 1.1,
      "instructions" => "Saved direction.",
      "extraBody" => %{"language" => "ja", "seed" => 7},
      "timeoutMs" => 60_000,
      "max_bytes" => 65_536,
      "advanced" => %{"operator_note" => "keep"}
    }

    {provider, credential} = saved(settings)
    endpoint = Gaoxy.Test.url(fixture, "/current/tenant/v1///")
    current_name = "current-local-openai-speech-#{Ecto.UUID.generate()}"
    current_settings = Map.put(settings, "voice", "Current Saved Voice")

    assert {:ok, _} =
             Providers.update(provider.id, %{
               name: current_name,
               base_url: endpoint,
               config: current_settings
             })

    assert {:ok, _} = Credentials.update(credential.id, %{key: "current-openai-speech-fixture"})
    assert :ok = Store.reload(:provider)
    assert {:ok, current} = Providers.openai_speech_config(provider.id)
    assert current.provider_name == current_name
    assert current.config.voice == "Current Saved Voice"
    assert current.config.instructions == "Saved direction."
    assert current.config.extra_body == %{"language" => "ja", "seed" => 7}
    assert current.timeout_ms == 30_000

    assert {:ok, prepared} =
             Providers.openai_speech_config(provider.id, %{
               "model" => "agent-studio-tts",
               "voice" => "Agent Voice",
               "response_format" => "wav",
               "speed" => 1.55,
               "instructions" => "Agent direction.",
               "extra_body" => %{"language" => "fr"},
               "timeout_ms" => 45_000
             })

    assert prepared.timeout_ms == 45_000
    assert prepared.config.base_url == Gaoxy.Test.url(fixture, "/current/tenant/v1")
    assert prepared.config.api_key == "current-openai-speech-fixture"
    owner = self()

    body = %{
      "model" => "agent-studio-tts",
      "input" => "  Exact current line.\n亲切  ",
      "voice" => "Agent Voice",
      "response_format" => "wav",
      "speed" => 1.55,
      "instructions" => "Agent direction.",
      "language" => "fr"
    }

    path = "/current/tenant/v1/audio/speech"

    Gaoxy.Test.expect_once(fixture, "POST", path, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert conn.request_path == path
      assert Jason.decode!(raw) == body
      send(owner, {:openai_current_http, conn.method, conn.request_path, raw})
      Plug.Conn.resp(conn, 200, <<82, 73, 70, 70, 0, 1, 2, 255>>)
    end)

    request = %{
      text: "  Exact current line.\n亲切  ",
      target: :audio_file,
      timeout_ms: 75_000,
      deadline_ms: System.monotonic_time(:millisecond) + 80_000
    }

    assert {:ok, built} = OpenAI.build_request(request, prepared.config)
    assert built.url == Gaoxy.Test.url(fixture, path)
    assert built.body == body
    assert built.timeout_ms == 75_000
    assert built.deadline_ms == request.deadline_ms

    assert OpenAI.synthesize(request, prepared.config) ==
             {:ok,
              %{
                audio: <<82, 73, 70, 70, 0, 1, 2, 255>>,
                output_format: "wav",
                file_extension: ".wav",
                voice_compatible: false
              }}

    assert_receive {:openai_current_http, "POST", ^path, raw}, 5_000
    assert Jason.decode!(raw) == body
    assert_saved(provider.id, current_name, endpoint, credential.id, current_settings)
  end

  defp assert_saved(id, name, endpoint, credential_id, settings) do
    assert {:ok, unchanged} = Providers.get(id)
    assert unchanged.id == id
    assert unchanged.name == name
    assert unchanged.type == "openai_speech"
    assert unchanged.preset == "openai-speech"
    assert unchanged.base_url == endpoint
    assert unchanged.credential_id == credential_id
    assert unchanged.config == settings
  end

  defp saved(config) do
    assert {:ok, credential} =
             Credentials.create(%{
               name: "openai-speech-credential-#{Ecto.UUID.generate()}",
               key: "initial-openai-speech-fixture"
             })

    on_exit(fn -> Credentials.delete(credential.id) end)

    assert {:ok, provider} =
             Providers.create(%{
               name: "arbitrary-openai-speech-#{Ecto.UUID.generate()}",
               type: "openai_speech",
               preset: "openai-speech",
               base_url: "https://Saved.Example/custom///",
               credential_id: credential.id,
               config: config
             })

    on_exit(fn -> Providers.delete(provider.id) end)
    {provider, credential}
  end
end
