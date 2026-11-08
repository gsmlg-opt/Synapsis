defmodule Synapsis.GoogleSpeechProviderFunctionalTest do
  use ExUnit.Case, async: false
  alias Synapsis.Config.Store
  alias Synapsis.Provider.{Registry, Speech.Google}
  alias Synapsis.{Credentials, Models, ProviderConfig, Providers}

  test "Google Speech is an explicit editable formal speech-only preset" do
    assert "google_speech" in ProviderConfig.valid_types()

    assert %{
             name: "google-speech",
             label: "Google Speech",
             type: "google_speech",
             base_url: "https://generativelanguage.googleapis.com/v1beta",
             base_url_editable: true,
             discover_models: false
           } = Enum.find(Providers.preset_providers(), &(&1.name == "google-speech"))

    assert Providers.speech_capabilities(%{type: "google_speech"}) == [:tts]
    assert Providers.speech_only?(%{type: "google_speech"})
    original = Store.list(:provider)
    original_ids = MapSet.new(original, & &1["id"])

    on_exit(fn ->
      Store.list(:provider)
      |> Enum.reject(&MapSet.member?(original_ids, &1["id"]))
      |> Enum.each(&Providers.delete(&1["id"]))
    end)

    assert :ok = Providers.seed_defaults()
    assert {:ok, providers} = Providers.list()
    refute Enum.any?(providers, &(&1.name == "google-speech"))
    for record <- original, do: assert({:ok, ^record} = Store.get(:provider, record["id"]))
  end

  test "arbitrary UUID and name retain advanced TOML fields and consume current referenced credential" do
    config = %{
      "model" => " google/gemini-3.1-flash-tts ",
      "voiceName" => " Puck ",
      "voice_name" => "snake-secondary",
      "voice" => "alias-secondary",
      "audioProfile" => " Warm ",
      "audio_profile" => "ignored-snake",
      "speakerName" => " Guide ",
      "speaker_name" => "ignored-name",
      "promptTemplate" => " audio-profile-v1 ",
      "personaPrompt" => " Speak clearly ",
      "timeout_ms" => 60_000,
      "max_bytes" => 8_192
    }

    {provider, credential} = saved(config)
    id = provider.id
    assert {:ok, ^id} = Ecto.UUID.cast(id)
    assert {:ok, ^provider} = Providers.get_by_name(provider.name)
    assert {:ok, prepared} = Providers.google_speech_config(id)

    assert prepared == %{
             provider_id: id,
             provider_name: provider.name,
             timeout_ms: 60_000,
             config: %{
               api_key: "initial-google-fixture",
               base_url: "https://generativelanguage.googleapis.com/v1beta",
               model: "gemini-3.1-flash-tts-preview",
               voice_name: "Puck",
               audio_profile: "Warm",
               speaker_name: "Guide",
               prompt_template: "audio-profile-v1",
               persona_prompt: "Speak clearly",
               max_bytes: 8_192
             }
           }

    endpoint = "https://google-speech-host.example/custom/v7"

    updated_config =
      config |> Map.put("voiceName", " Aoede ") |> Map.put("personaPrompt", " Current notes ")

    assert {:ok, _} = Providers.update(id, %{base_url: endpoint, config: updated_config})
    assert {:ok, _} = Credentials.update(credential.id, %{key: "current-google-fixture"})
    assert {:ok, toml} = Toml.decode(File.read!(Store.file_path(:provider)))
    assert persisted = Enum.find(toml["providers"], &(&1["id"] == id))

    assert Map.take(persisted, ~w(id name type preset base_url credential_id config)) == %{
             "id" => id,
             "name" => provider.name,
             "type" => "google_speech",
             "preset" => "google-speech",
             "base_url" => endpoint,
             "credential_id" => credential.id,
             "config" => updated_config
           }

    assert :ok = Store.reload(:provider)
    assert {:ok, current_provider} = Providers.get(id)
    assert current_provider.config == updated_config
    assert current_provider.credential_id == credential.id
    assert {:ok, current} = Providers.google_speech_config(id)

    assert current == %{
             prepared
             | config: %{
                 prepared.config
                 | api_key: "current-google-fixture",
                   base_url: endpoint,
                   voice_name: "Aoede",
                   persona_prompt: "Current notes"
               }
           }

    assert {:ok, runtime} = Providers.runtime_config(provider.name)
    assert runtime.provider_id == id
    assert runtime.provider_name == provider.name
    assert runtime.api_key == "current-google-fixture"
    assert {:ok, ^runtime} = Registry.get(provider.name)
    assert Providers.model_suggestions(current_provider) == []
    assert {:ok, []} = Models.list(provider_id: id)

    assert {:ok, overlay} =
             Providers.google_speech_config(id, %{
               "model" => " google/gemini-3.8-flash-lite-tts ",
               "voice" => "secondary",
               "voice_name" => " Zephyr ",
               "audio_profile" => " Bright ",
               "speaker_name" => " Narrator ",
               "persona_prompt" => " Agent notes ",
               "timeout_ms" => 45_000,
               "max_bytes" => 16_384
             })

    assert overlay == %{
             current
             | timeout_ms: 45_000,
               config: %{
                 current.config
                 | model: "gemini-3.8-flash-lite-tts",
                   voice_name: "Zephyr",
                   audio_profile: "Bright",
                   speaker_name: "Narrator",
                   persona_prompt: "Agent notes",
                   max_bytes: 16_384
               }
           }
  end

  test "saved snake settings and explicit Agent cast overlay keep canonical data" do
    cast = [
      %{"name" => " Puck ", "voiceName" => " Puck ", "style" => " Bright "},
      %{"speaker" => " Kore ", "voice" => " Kore "}
    ]

    {provider, _} =
      saved(%{
        "model" => "gemini-3.8-flash-tts",
        "voice_name" => "Custom Voice",
        "audio_profile" => "Warm",
        "speaker_name" => "Narrator",
        "prompt_template" => "audio-profile-v1",
        "persona_prompt" => "Calm",
        "speakers" => cast
      })

    assert {:ok, prepared} = Providers.google_speech_config(provider.id)
    assert prepared.timeout_ms == 30_000
    assert prepared.config.model == "gemini-3.8-flash-tts"
    assert prepared.config.voice_name == "Custom Voice"
    assert prepared.config.audio_profile == "Warm"
    assert prepared.config.speaker_name == "Narrator"
    assert prepared.config.prompt_template == "audio-profile-v1"
    assert prepared.config.persona_prompt == "Calm"

    assert prepared.config.speakers == [
             %{speaker: "Puck", voice: "Puck", style: "Bright"},
             %{speaker: "Kore", voice: "Kore"}
           ]

    cast = [
      %{"speaker" => "First", "voice" => "Aoede"},
      %{"speaker" => "Second", "voice" => "Zephyr", "style" => "Clear"}
    ]

    assert {:ok, overlaid} =
             Providers.google_speech_config(provider.id, %{
               "speakers" => cast,
               "timeout_ms" => 30_000
             })

    assert overlaid.config.speakers == [
             %{speaker: "First", voice: "Aoede"},
             %{speaker: "Second", voice: "Zephyr", style: "Clear"}
           ]

    assert overlaid.provider_id == provider.id
    assert overlaid.timeout_ms == 30_000
  end

  test "saved preparation serves explicit Talk, voice-note and dedicated telephony through real HTTP" do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)

    {provider, credential} =
      saved(%{
        "model" => "gemini-3.8-flash-tts",
        "voice_name" => "Puck",
        "audio_profile" => "Warm",
        "persona_prompt" => "Calm"
      })

    assert {:ok, _} =
             Providers.update(provider.id, %{base_url: Gaoxy.Test.url(fixture, "/v1beta")})

    assert {:ok, _} = Credentials.update(credential.id, %{key: "current-google-fixture"})
    assert {:ok, prepared} = Providers.google_speech_config(provider.id)
    owner = self()

    pcm =
      for n <- 0..2_399,
          into: <<>>,
          do: <<round(12_000 * :math.sin(2 * :math.pi() * 440 * n / 24_000))::little-signed-16>>

    Gaoxy.Test.stub(fixture, "POST", "/v1beta/interactions", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Plug.Conn.get_req_header(conn, "x-goog-api-key") == ["current-google-fixture"]

      assert Jason.decode!(raw) == %{
               "model" => "gemini-3.8-flash-lite-tts",
               "store" => false,
               "input" => [
                 %{
                   "type" => "user_input",
                   "content" => [
                     %{
                       "type" => "text",
                       "text" => "A saved Talk line.",
                       "annotations" => [
                         %{"type" => "speech_metadata", "style" => "Warm\n\nCalm"}
                       ]
                     }
                   ]
                 }
               ],
               "response_format" => %{
                 "type" => "audio",
                 "mime_type" => "audio/l16",
                 "sample_rate" => 24_000
               },
               "generation_config" => %{"speech_config" => [%{"voice" => "Aoede"}]}
             }

      send(owner, :saved_google_request)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"output_audio" => %{"data" => Base.encode64(pcm)}}))
    end)

    # Talk configuration is explicit input derived from this saved identity.
    base = %{
      "providers" => %{
        "google" => %{
          "apiKey" => prepared.config.api_key,
          "baseUrl" => prepared.config.base_url,
          "model" => prepared.config.model,
          "voiceName" => prepared.config.voice_name,
          "audioProfile" => prepared.config.audio_profile,
          "personaPrompt" => prepared.config.persona_prompt
        }
      }
    }

    config = Google.resolve_talk_config(base, %{})
    assert config == Map.drop(prepared.config, [:max_bytes])

    overrides =
      Google.resolve_talk_overrides(%{
        "modelId" => "gemini-3.8-flash-lite-tts",
        "voiceId" => "Aoede"
      })

    text = "A saved Talk line."

    for target <- [:audio_file, :voice_note, :telephony] do
      assert {:ok, nil} =
               Google.prepare_synthesis(%{
                 text: text,
                 provider_config: config,
                 provider_overrides: overrides
               })

      request = %{
        text: text,
        target: target,
        timeout_ms: prepared.timeout_ms,
        provider_overrides: overrides
      }

      if target == :telephony do
        assert {:ok, %{audio: ^pcm, output_format: "pcm", sample_rate: 24_000}} =
                 Google.synthesize_telephony(request, config)
      else
        assert {:ok, result} = Google.synthesize(request, config)

        if target == :voice_note do
          assert result.output_format == "opus"
          assert result.voice_compatible
          assert <<"OggS", _::binary>> = result.audio
          assert :binary.match(result.audio, "OpusHead") != :nomatch
        else
          assert result.output_format == "wav"

          assert <<"RIFF", _::binary-size(4), "WAVE", _::binary-size(32), ^pcm::binary>> =
                   result.audio
        end
      end

      assert_receive :saved_google_request, 5_000
    end
  end

  defp saved(config) do
    assert {:ok, credential} =
             Credentials.create(%{
               name: "google-credential-#{Ecto.UUID.generate()}",
               key: "initial-google-fixture"
             })

    on_exit(fn -> Credentials.delete(credential.id) end)

    assert {:ok, provider} =
             Providers.create(%{
               name: "my-google-voice-#{Ecto.UUID.generate()}",
               type: "google_speech",
               preset: "google-speech",
               credential_id: credential.id,
               config: config
             })

    on_exit(fn -> Providers.delete(provider.id) end)
    {provider, credential}
  end
end
