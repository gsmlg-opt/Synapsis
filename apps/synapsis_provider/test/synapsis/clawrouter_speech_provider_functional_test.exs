defmodule Synapsis.ClawRouterSpeechProviderFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Config.Store
  alias Synapsis.Provider.{Registry, Speech.ClawRouter}
  alias Synapsis.{Credentials, Models, ProviderConfig, Providers}

  test "formal ClawRouter editable preset is static TTS only and remains opt-in" do
    assert "clawrouter_speech" in ProviderConfig.valid_types()

    assert %{
             name: "clawrouter-speech",
             label: "ClawRouter",
             type: "clawrouter_speech",
             base_url: "https://clawrouter.openclaw.ai/v1",
             base_url_editable: true,
             discover_models: false
           } = Enum.find(Providers.preset_providers(), &(&1.name == "clawrouter-speech"))

    assert Providers.default_base_url("clawrouter_speech") == "https://clawrouter.openclaw.ai/v1"
    assert Providers.speech_capabilities(%{type: "clawrouter_speech"}) == [:tts]
    assert Providers.speech_only?(%{type: "clawrouter_speech"})
    original = Store.list(:provider)
    original_ids = MapSet.new(original, & &1["id"])
    original_clawrouter = Enum.filter(original, &(&1["type"] == "clawrouter_speech"))

    on_exit(fn ->
      Store.list(:provider)
      |> Enum.reject(&MapSet.member?(original_ids, &1["id"]))
      |> Enum.each(&Providers.delete(&1["id"]))
    end)

    assert :ok = Providers.seed_defaults()

    assert Enum.filter(Store.list(:provider), &(&1["type"] == "clawrouter_speech")) ==
             original_clawrouter

    for record <- original, do: assert({:ok, ^record} = Store.get(:provider, record["id"]))
  end

  test "current saved UUID connection and referenced value retain complete advanced TOML" do
    settings = %{
      "modelId" => " openai/tts-1 ",
      "speakerVoiceId" => " fable ",
      "voice" => "echo",
      "responseFormat" => " AAC ",
      "speed" => 1.35,
      "timeoutMs" => 60_000,
      "timeout_ms" => 75_000,
      "max_bytes" => 65_536,
      "operator_note" => "Preserve complete advanced settings",
      "advanced" => %{"custom" => ["one", "two"]}
    }

    {provider, credential} = saved(settings)
    id = provider.id
    assert {:ok, ^id} = Ecto.UUID.cast(id)
    assert {:ok, by_name} = Providers.get_by_name(provider.name)
    assert by_name.id == id
    assert by_name.api_key_encrypted == "initial-clawrouter-fixture"
    assert {:ok, prepared} = Providers.clawrouter_speech_config(id)

    assert prepared == %{
             provider_id: id,
             provider_name: provider.name,
             timeout_ms: 30_000,
             config: %{
               api_key: "initial-clawrouter-fixture",
               base_url: "https://Saved.Example/custom/v1///",
               model: "openai/tts-1",
               voice: "fable",
               response_format: "aac",
               speed: 1.35,
               max_bytes: 65_536
             }
           }

    assert {:ok, built} =
             ClawRouter.build_request(
               %{text: "Saved speech.", target: :audio_file, timeout_ms: 21_123.75},
               prepared.config
             )

    assert built.url == "https://Saved.Example/custom/v1/audio/speech"
    assert built.timeout_ms === 21_123.75

    endpoint = "https://Current.Example/tenant/v1/v1///"
    updated_settings = Map.put(settings, "speakerVoiceId", " shimmer ")
    assert {:ok, _} = Providers.update(id, %{base_url: endpoint, config: updated_settings})
    assert {:ok, _} = Credentials.update(credential.id, %{key: "current-clawrouter-fixture"})
    assert {:ok, toml} = Toml.decode(File.read!(Store.file_path(:provider)))
    persisted = Enum.find(toml["providers"], &(&1["id"] == id))

    assert Map.take(persisted, ~w(id name type preset base_url credential_id config)) == %{
             "id" => id,
             "name" => provider.name,
             "type" => "clawrouter_speech",
             "preset" => "clawrouter-speech",
             "base_url" => endpoint,
             "credential_id" => credential.id,
             "config" => updated_settings
           }

    assert :ok = Store.reload(:provider)
    assert {:ok, reopened} = Providers.get(id)
    assert reopened.config == updated_settings
    assert reopened.credential_id == credential.id
    assert reopened.api_key_encrypted == "current-clawrouter-fixture"
    assert {:ok, current} = Providers.clawrouter_speech_config(id)

    assert current == %{
             prepared
             | config: %{
                 prepared.config
                 | api_key: "current-clawrouter-fixture",
                   base_url: endpoint,
                   voice: "shimmer"
               }
           }

    assert {:ok, runtime} = Providers.runtime_config(provider.name)
    assert runtime.provider_id == id
    assert runtime.provider_name == provider.name
    assert runtime.base_url == endpoint
    assert runtime.api_key == "current-clawrouter-fixture"
    assert {:ok, ^runtime} = Registry.get(provider.name)
    assert Providers.model_suggestions(reopened) == []
    assert {:ok, []} = Models.list(provider_id: id)

    assert {:ok, overlaid} =
             Providers.clawrouter_speech_config(id, %{
               "model_id" => " openai/tts-1 ",
               "voice_id" => " nova ",
               "response_format" => " OPUS ",
               "speed" => 1.65,
               "timeout_ms" => 45_000,
               "max_bytes" => 131_072
             })

    assert overlaid == %{
             current
             | timeout_ms: 45_000,
               config: %{
                 current.config
                 | voice: "nova",
                   response_format: "opus",
                   speed: 1.65,
                   max_bytes: 131_072
               }
           }

    assert {:ok, built} =
             ClawRouter.build_request(
               %{text: "Agent overlay.", target: :audio_file, timeout_ms: 75_000},
               overlaid.config
             )

    assert built.url == "https://Current.Example/tenant/v1/v1/audio/speech"
    assert built.timeout_ms == 75_000

    assert built.body == %{
             "model" => "openai/tts-1",
             "input" => "Agent overlay.",
             "voice" => "nova",
             "response_format" => "opus",
             "speed" => 1.65
           }

    assert {:ok, unchanged} = Providers.get(id)
    assert unchanged.config == updated_settings
    assert unchanged.base_url == endpoint
    assert unchanged.credential_id == credential.id
  end

  for {settings, voice} <- [
        {%{"model_id" => " openai/tts-1 ", "speaker_voice_id" => " echo ", "voice_id" => "nova"},
         "echo"},
        {%{"model" => " openai/tts-1 ", "speaker_voice" => " fable "}, "fable"},
        {%{"modelId" => " openai/tts-1 ", "voiceId" => " onyx "}, "onyx"}
      ] do
    @settings settings
    @voice voice
    test "saved source and snake aliases normalize before partial Agent voice overlay #{@voice}" do
      settings = Map.merge(@settings, %{"response_format" => " FLAC ", "speed" => 1.4})
      {provider, _credential} = saved(settings)
      assert {:ok, prepared} = Providers.clawrouter_speech_config(provider.id)
      assert prepared.timeout_ms == 30_000
      assert prepared.config.model == "openai/tts-1"
      assert prepared.config.voice == @voice
      assert prepared.config.response_format == "flac"
      assert prepared.config.speed === 1.4
      assert prepared.config.max_bytes == 16 * 1024 * 1024

      assert {:ok, overlaid} =
               Providers.clawrouter_speech_config(provider.id, %{"voice_id" => " shimmer "})

      assert overlaid == %{prepared | config: %{prepared.config | voice: "shimmer"}}
      assert {:ok, unchanged} = Providers.get(provider.id)
      assert unchanged.config == settings
    end
  end

  test "current saved route and canonical Agent settings send exact ordinary HTTP" do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)

    {provider, credential} =
      saved(%{
        "modelId" => "openai/tts-1",
        "speakerVoiceId" => "echo",
        "responseFormat" => "aac",
        "speed" => 1.1,
        "timeoutMs" => 60_000,
        "max_bytes" => 65_536,
        "advanced" => %{"operator_note" => "keep"}
      })

    endpoint = Gaoxy.Test.url(fixture, "/current/tenant/v1///")
    assert {:ok, _} = Providers.update(provider.id, %{base_url: endpoint})
    assert {:ok, _} = Credentials.update(credential.id, %{key: "current-clawrouter-fixture"})

    assert {:ok, prepared} =
             Providers.clawrouter_speech_config(provider.id, %{
               "model_id" => "openai/tts-1",
               "voice_id" => "nova",
               "response_format" => " WAV ",
               "speed" => 1.55,
               "timeout_ms" => 45_000
             })

    assert prepared.timeout_ms == 45_000
    assert prepared.config.base_url == endpoint
    assert prepared.config.api_key == "current-clawrouter-fixture"

    body = %{
      "model" => "openai/tts-1",
      "input" => "  Exact current line.\n亲切  ",
      "voice" => "nova",
      "response_format" => "wav",
      "speed" => 1.55
    }

    owner = self()

    Gaoxy.Test.stub(fixture, "POST", "/current/tenant/v1/audio/speech", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw) == body
      send(owner, {:clawrouter_current_http, conn.request_path, raw})
      Plug.Conn.resp(conn, 200, "fixture8")
    end)

    request = %{text: "  Exact current line.\n亲切  ", target: :audio_file, timeout_ms: 75_000}
    assert {:ok, built} = ClawRouter.build_request(request, prepared.config)
    assert built.url == Gaoxy.Test.url(fixture, "/current/tenant/v1/audio/speech")
    assert built.body == body
    assert built.timeout_ms == 75_000

    assert ClawRouter.synthesize(request, prepared.config) ==
             {:ok,
              %{
                audio: "fixture8",
                output_format: "wav",
                file_extension: ".wav",
                voice_compatible: false
              }}

    assert_receive {:clawrouter_current_http, "/current/tenant/v1/audio/speech", raw}, 5_000
    assert Jason.decode!(raw) == body
  end

  defp saved(config) do
    assert {:ok, credential} =
             Credentials.create(%{
               name: "clawrouter-credential-#{Ecto.UUID.generate()}",
               key: "initial-clawrouter-fixture"
             })

    on_exit(fn -> Credentials.delete(credential.id) end)

    assert {:ok, provider} =
             Providers.create(%{
               name: "arbitrary-clawrouter-#{Ecto.UUID.generate()}",
               type: "clawrouter_speech",
               preset: "clawrouter-speech",
               base_url: "https://Saved.Example/custom/v1///",
               credential_id: credential.id,
               config: config
             })

    on_exit(fn -> Providers.delete(provider.id) end)
    {provider, credential}
  end
end
