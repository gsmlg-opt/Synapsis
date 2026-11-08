defmodule Synapsis.AzureSpeechProviderFunctionalTest do
  use ExUnit.Case, async: false
  alias Synapsis.Config.Store
  alias Synapsis.Provider.{Registry, Speech.Azure}
  alias Synapsis.{Credentials, Models, ProviderConfig, Providers}

  test "Azure Speech is a formal editable blank-endpoint speech-only preset" do
    assert "azure_speech" in ProviderConfig.valid_types()

    assert %{
             name: "azure-speech",
             label: "Azure Speech",
             type: "azure_speech",
             base_url: "",
             base_url_editable: true,
             discover_models: false
           } = Enum.find(Providers.preset_providers(), &(&1.name == "azure-speech"))

    assert Providers.speech_capabilities(%{type: "azure_speech"}) == [:tts]
    assert Providers.speech_only?(%{type: "azure_speech"})
    assert Providers.default_base_url("azure_speech") == ""
    original = Store.list(:provider)
    original_ids = MapSet.new(original, & &1["id"])
    original_azure = Enum.filter(original, &(&1["type"] == "azure_speech"))

    on_exit(fn ->
      Store.list(:provider)
      |> Enum.reject(&MapSet.member?(original_ids, &1["id"]))
      |> Enum.each(&Providers.delete(&1["id"]))
    end)

    assert :ok = Providers.seed_defaults()
    assert Enum.filter(Store.list(:provider), &(&1["type"] == "azure_speech")) == original_azure
    for record <- original, do: assert({:ok, ^record} = Store.get(:provider, record["id"]))
  end

  test "UUID and arbitrary name preserve advanced TOML and prepare the current referenced connection" do
    config = %{
      "voice" => " SavedVoice ",
      "voiceId" => "secondary-alias",
      "voice_id" => "secondary-snake",
      "lang" => " en-GB ",
      "languageCode" => "secondary-language",
      "outputFormat" => " riff-24khz-16bit-mono-pcm ",
      "output_format" => "secondary-format",
      "voiceNoteOutputFormat" => " webm-24khz-16bit-mono-opus ",
      "voice_note_output_format" => "secondary-note-format",
      "timeoutMs" => 60_000,
      "timeout_ms" => 75_000,
      "max_bytes" => 8_192,
      "operator_note" => "Keep the complete advanced record"
    }

    {provider, credential} = saved(config)
    id = provider.id
    assert {:ok, ^id} = Ecto.UUID.cast(id)
    assert {:ok, ^provider} = Providers.get_by_name(provider.name)
    assert {:ok, prepared} = Providers.azure_speech_config(id)

    assert prepared == %{
             provider_id: id,
             provider_name: provider.name,
             timeout_ms: 60_000,
             config: %{
               api_key: "initial-azure-fixture",
               base_url: "https://saved-azure.example/tenant",
               voice: "SavedVoice",
               lang: "en-GB",
               output_format: "riff-24khz-16bit-mono-pcm",
               voice_note_output_format: "webm-24khz-16bit-mono-opus",
               timeout_ms: 60_000,
               max_bytes: 8_192
             }
           }

    endpoint = "https://current-azure.example/custom/root"
    updated_config = Map.put(config, "voice", " CurrentVoice ")
    assert {:ok, _} = Providers.update(id, %{base_url: endpoint, config: updated_config})
    assert {:ok, _} = Credentials.update(credential.id, %{key: "current-azure-fixture"})
    assert {:ok, toml} = Toml.decode(File.read!(Store.file_path(:provider)))
    assert persisted = Enum.find(toml["providers"], &(&1["id"] == id))

    assert Map.take(persisted, ~w(id name type preset base_url credential_id config)) == %{
             "id" => id,
             "name" => provider.name,
             "type" => "azure_speech",
             "preset" => "azure-speech",
             "base_url" => endpoint,
             "credential_id" => credential.id,
             "config" => updated_config
           }

    assert :ok = Store.reload(:provider)
    assert {:ok, current_provider} = Providers.get(id)
    assert current_provider.config == updated_config
    assert current_provider.credential_id == credential.id
    assert {:ok, current} = Providers.azure_speech_config(id)

    assert current == %{
             prepared
             | config: %{
                 prepared.config
                 | api_key: "current-azure-fixture",
                   base_url: endpoint,
                   voice: "CurrentVoice"
               }
           }

    assert {:ok, runtime} = Providers.runtime_config(provider.name)
    assert runtime.provider_id == id
    assert runtime.provider_name == provider.name
    assert runtime.api_key == "current-azure-fixture"
    assert runtime.base_url == endpoint
    assert {:ok, ^runtime} = Registry.get(provider.name)
    assert Providers.model_suggestions(current_provider) == []
    assert {:ok, []} = Models.list(provider_id: id)

    assert {:ok, overlay} =
             Providers.azure_speech_config(id, %{
               "voice_id" => " fr-FR-DeniseNeural ",
               "language_code" => " fr-FR ",
               "output_format" => " amr-16khz-32kbps ",
               "voice_note_output_format" => " ogg-24khz-16bit-mono-opus ",
               "timeout_ms" => 45_000,
               "max_bytes" => 16_384
             })

    assert overlay == %{
             current
             | timeout_ms: 45_000,
               config: %{
                 current.config
                 | voice: "fr-FR-DeniseNeural",
                   lang: "fr-FR",
                   output_format: "amr-16khz-32kbps",
                   voice_note_output_format: "ogg-24khz-16bit-mono-opus",
                   timeout_ms: 45_000,
                   max_bytes: 16_384
               }
           }

    # Explicit overlays affect this call, preserving the saved advanced record.
    assert {:ok, unchanged} = Providers.get(id)
    assert unchanged.config == updated_config
    assert unchanged.base_url == endpoint
    assert unchanged.credential_id == credential.id
  end

  test "saved snake settings and absent configured timeout retain request fallback semantics" do
    config = %{
      "voice_id" => " CustomVoice ",
      "language_code" => " ja-JP ",
      "output_format" => " raw-24khz-16bit-mono-pcm ",
      "voice_note_output_format" => " OGG-24KHZ-MONO-OPUS "
    }

    {provider, _credential} = saved(config)
    assert {:ok, prepared} = Providers.azure_speech_config(provider.id)

    assert prepared == %{
             provider_id: provider.id,
             provider_name: provider.name,
             timeout_ms: 30_000,
             config: %{
               api_key: "initial-azure-fixture",
               base_url: "https://saved-azure.example/tenant",
               voice: "CustomVoice",
               lang: "ja-JP",
               output_format: "raw-24khz-16bit-mono-pcm",
               voice_note_output_format: "OGG-24KHZ-MONO-OPUS",
               max_bytes: 16 * 1024 * 1024
             }
           }

    refute Map.has_key?(prepared.config, :timeout_ms)
    request = %{text: "A saved line.", target: :audio_file, timeout_ms: 75_000}
    assert {:ok, built} = Azure.build_request(request, prepared.config)
    assert built.timeout_ms == 75_000

    assert {:ok, overlaid} =
             Providers.azure_speech_config(provider.id, %{
               voice: " AgentVoice ",
               lang: " de-DE ",
               timeout_ms: 45_000,
               max_bytes: 24_576
             })

    assert overlaid.provider_id == provider.id
    assert overlaid.provider_name == provider.name
    assert overlaid.timeout_ms == 45_000
    expected_config = Map.put(prepared.config, :timeout_ms, 45_000)

    assert overlaid.config == %{
             expected_config
             | voice: "AgentVoice",
               lang: "de-DE",
               max_bytes: 24_576
           }

    assert {:ok, built} = Azure.build_request(request, overlaid.config)
    assert built.timeout_ms == 45_000
    assert {:ok, saved_provider} = Providers.get(provider.id)
    assert saved_provider.config == config
  end

  test "saved preparation composes explicit Talk, voice-note, generic telephony and dedicated callback" do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)

    {provider, credential} =
      saved(%{
        "voice" => "SavedVoice",
        "lang" => "en-GB",
        "outputFormat" => "riff-24khz-16bit-mono-pcm",
        "voiceNoteOutputFormat" => "webm-24khz-16bit-mono-opus",
        "timeoutMs" => 60_000,
        "max_bytes" => 8_192
      })

    assert {:ok, _} =
             Providers.update(provider.id, %{base_url: Gaoxy.Test.url(fixture, "/tenant")})

    assert {:ok, _} = Credentials.update(credential.id, %{key: "current-azure-fixture"})
    assert {:ok, prepared} = Providers.azure_speech_config(provider.id)
    assert prepared.provider_name == provider.name
    assert prepared.config.timeout_ms == 60_000

    source = %{
      "apiKey" => prepared.config.api_key,
      "baseUrl" => prepared.config.base_url,
      "voice" => prepared.config.voice,
      "lang" => prepared.config.lang,
      "outputFormat" => prepared.config.output_format,
      "voiceNoteOutputFormat" => prepared.config.voice_note_output_format,
      "timeoutMs" => prepared.config.timeout_ms
    }

    base = %{"providers" => %{"azure-speech" => source}}

    config =
      Azure.resolve_talk_config(base, %{"voiceId" => " TalkVoice ", "languageCode" => " fr-FR "})

    expected_config = Map.drop(prepared.config, [:max_bytes])
    assert config == %{expected_config | voice: "TalkVoice", lang: "fr-FR"}

    overrides =
      Azure.resolve_talk_overrides(%{"voiceId" => " TalkOverride ", "languageCode" => " ja-JP "})

    assert overrides == %{voice: "TalkOverride", lang: "ja-JP"}
    counter = :counters.new(1, [])

    body =
      ~s(<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="ja-JP"><voice name="TalkOverride">A saved Talk line.</voice></speak>)

    Gaoxy.Test.stub(fixture, "POST", "/tenant/cognitiveservices/v1", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert raw == body

      assert Plug.Conn.get_req_header(conn, "ocp-apim-subscription-key") == [
               "current-azure-fixture"
             ]

      :counters.add(counter, 1, 1)
      Plug.Conn.resp(conn, 200, <<0, 1, 2, 254, 255>>)
    end)

    for {target, format, extension, compatible} <- [
          {:audio_file, "riff-24khz-16bit-mono-pcm", ".wav", false},
          {:voice_note, "webm-24khz-16bit-mono-opus", ".webm", false},
          {:telephony, "riff-24khz-16bit-mono-pcm", ".wav", false}
        ] do
      request = %{
        text: "A saved Talk line.",
        target: target,
        timeout_ms: 10_000,
        provider_overrides: overrides
      }

      assert {:ok, built} = Azure.build_request(request, config)
      assert built.timeout_ms == 60_000
      assert {"x-microsoft-outputformat", format} in built.headers

      assert Azure.synthesize(request, config) ==
               {:ok,
                %{
                  audio: <<0, 1, 2, 254, 255>>,
                  output_format: format,
                  file_extension: extension,
                  voice_compatible: compatible,
                  media_format: String.trim_leading(extension, ".")
                }}
    end

    request = %{
      text: "A saved Talk line.",
      target: :voice_note,
      timeout_ms: 10_000,
      provider_overrides: Map.put(overrides, :output_format, "amr-16khz-32kbps")
    }

    assert Azure.synthesize_telephony(request, config) ==
             {:ok,
              %{
                audio: <<0, 1, 2, 254, 255>>,
                output_format: "raw-8khz-8bit-mono-mulaw",
                sample_rate: 8_000
              }}

    assert :counters.get(counter, 1) == 4

    Gaoxy.Test.stub(fixture, "GET", "/tenant/cognitiveservices/voices/list", fn conn ->
      assert Plug.Conn.get_req_header(conn, "ocp-apim-subscription-key") == [
               "current-azure-fixture"
             ]

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!([
          %{
            "ShortName" => " CustomSavedVoice ",
            "DisplayName" => " Custom saved voice ",
            "Status" => "Active"
          },
          %{"ShortName" => "TalkVoice", "DisplayName" => "Talk voice", "Status" => "Preview"}
        ])
      )
    end)

    assert Azure.list_voices(%{timeout_ms: 10_000}, config) ==
             {:ok,
              [
                %{id: "CustomSavedVoice", name: "Custom saved voice"},
                %{id: "TalkVoice", name: "Talk voice"}
              ]}
  end

  defp saved(config) do
    assert {:ok, credential} =
             Credentials.create(%{
               name: "azure-credential-#{Ecto.UUID.generate()}",
               key: "initial-azure-fixture"
             })

    on_exit(fn -> Credentials.delete(credential.id) end)

    assert {:ok, provider} =
             Providers.create(%{
               name: "my-regional-voice-#{Ecto.UUID.generate()}",
               type: "azure_speech",
               preset: "azure-speech",
               base_url: "https://saved-azure.example/tenant",
               credential_id: credential.id,
               config: config
             })

    on_exit(fn -> Providers.delete(provider.id) end)
    {provider, credential}
  end
end
