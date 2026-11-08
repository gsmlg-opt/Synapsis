defmodule Synapsis.FishAudioSpeechProviderFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Config.Store
  alias Synapsis.Provider.Registry
  alias Synapsis.{Credentials, Models, ProviderConfig, Providers}

  test "Fish Audio is an explicit editable TTS-only preset with no LLM catalog" do
    assert "fish_audio_speech" in ProviderConfig.valid_types()

    assert %{
             name: "fish-audio-speech",
             label: "Fish Audio Speech",
             type: "fish_audio_speech",
             base_url: "https://api.fish.audio",
             base_url_editable: true,
             discover_models: false
           } =
             Enum.find(Providers.preset_providers(), &(&1.name == "fish-audio-speech"))

    assert Providers.speech_capabilities(%{type: "fish_audio_speech"}) == [:tts]
    assert Providers.speech_only?(%{type: "fish_audio_speech"})
    original = Store.list(:provider)
    original_ids = MapSet.new(original, & &1["id"])

    on_exit(fn ->
      Store.list(:provider)
      |> Enum.reject(&MapSet.member?(original_ids, &1["id"]))
      |> Enum.each(&Providers.delete(&1["id"]))
    end)

    assert :ok = Providers.seed_defaults()
    assert {:ok, providers} = Providers.list()
    refute Enum.any?(providers, &(&1.name == "fish-audio-speech"))
    for record <- original, do: assert({:ok, ^record} = Store.get(:provider, record["id"]))
  end

  test "saved UUID arbitrary name aliases current credential and TOML retain exact preparation authority" do
    assert {:ok, credential} =
             Credentials.create(%{
               name: "fish-credential-#{Ecto.UUID.generate()}",
               key: "initial-fish-fixture"
             })

    on_exit(fn -> Credentials.delete(credential.id) end)

    config = %{
      "modelId" => " drama-3 ",
      "speakerVoiceId" => " saved-primary ",
      "voiceId" => "secondary",
      "referenceId" => "third",
      "latency" => " LOW ",
      "speed" => 1.2,
      "temperature" => 0.7,
      "topP" => 0.6,
      "top_p" => 0.4,
      "normalize" => false,
      "timeout_ms" => 60_000,
      "max_bytes" => 8_192
    }

    name = "my-fish-voice-#{Ecto.UUID.generate()}"

    assert {:ok, provider} =
             Providers.create(%{
               name: name,
               type: "fish_audio_speech",
               preset: "fish-audio-speech",
               credential_id: credential.id,
               config: config
             })

    on_exit(fn -> Providers.delete(provider.id) end)
    id = provider.id
    assert {:ok, ^id} = Ecto.UUID.cast(id)
    assert {:ok, ^provider} = Providers.get(id)
    assert {:ok, ^provider} = Providers.get_by_name(name)
    assert Providers.model_suggestions(provider) == []
    assert {:ok, []} = Models.list(provider_id: id)
    assert {:ok, prepared} = Providers.fish_audio_config(id)

    assert prepared == %{
             provider_id: id,
             provider_name: name,
             timeout_ms: 60_000,
             config: %{
               api_key: "initial-fish-fixture",
               base_url: "https://api.fish.audio",
               model: "drama-3",
               reference_id: "saved-primary",
               latency: "low",
               speed: 1.2,
               temperature: 0.7,
               top_p: 0.6,
               normalize: false,
               max_bytes: 8_192
             }
           }

    endpoint = "https://fish-host.example/custom/v7"

    updated_config =
      config |> Map.put("speakerVoiceId", " updated-primary ") |> Map.put("speed", 1.3)

    assert {:ok, updated} = Providers.update(id, %{base_url: endpoint, config: updated_config})
    assert {:ok, toml} = Toml.decode(File.read!(Store.file_path(:provider)))
    assert persisted = Enum.find(toml["providers"], &(&1["id"] == id))

    assert Map.take(persisted, ~w(id name type preset base_url credential_id config)) == %{
             "id" => id,
             "name" => name,
             "type" => "fish_audio_speech",
             "preset" => "fish-audio-speech",
             "base_url" => endpoint,
             "credential_id" => credential.id,
             "config" => updated_config
           }

    assert {:ok, _} = Credentials.update(credential.id, %{key: "current-fish-fixture"})
    assert :ok = Store.reload(:provider)
    current_provider = %{updated | api_key_encrypted: "current-fish-fixture"}
    assert {:ok, ^current_provider} = Providers.get(id)
    assert {:ok, ^current_provider} = Providers.get_by_name(name)
    assert {:ok, runtime} = Providers.runtime_config(name)
    assert runtime.provider_id == id
    assert runtime.provider_name == name
    assert runtime.api_key == "current-fish-fixture"
    assert runtime.base_url == endpoint
    assert {:ok, ^runtime} = Registry.get(name)
    assert {:ok, current} = Providers.fish_audio_config(id)

    assert current == %{
             prepared
             | config: %{
                 prepared.config
                 | api_key: "current-fish-fixture",
                   base_url: endpoint,
                   reference_id: "updated-primary",
                   speed: 1.3
               }
           }

    assert {:ok, overlay} =
             Providers.fish_audio_config(id, %{
               "model" => " s1 ",
               "voice_id" => " agent-primary ",
               "reference_id" => "agent-secondary",
               "latency" => " NORMAL ",
               "speed" => 1.4,
               "temperature" => 0.45,
               "top_p" => 0.35,
               "normalize" => false,
               "timeout_ms" => 45_000
             })

    assert overlay == %{
             current
             | timeout_ms: 45_000,
               config: %{
                 current.config
                 | model: "s1",
                   reference_id: "agent-primary",
                   latency: "normal",
                   speed: 1.4,
                   temperature: 0.45,
                   top_p: 0.35,
                   normalize: false
               }
           }

    assert {:ok, []} = Models.list(provider_id: id)
  end

  test "saved snake aliases and defaults normalize before Agent canonical overlay" do
    assert {:ok, credential} =
             Credentials.create(%{
               name: "fish-default-#{Ecto.UUID.generate()}",
               key: "ordinary-fish-fixture"
             })

    on_exit(fn -> Credentials.delete(credential.id) end)

    assert {:ok, provider} =
             Providers.create(%{
               name: "arbitrary-voice-#{Ecto.UUID.generate()}",
               type: "fish_audio_speech",
               preset: "fish-audio-speech",
               credential_id: credential.id,
               config: %{
                 "model_id" => "s2-pro",
                 "speaker_voice_id" => "snake-speaker",
                 "voice_id" => "snake-secondary",
                 "reference_id" => "snake-third",
                 "top_p" => 0.3
               }
             })

    on_exit(fn -> Providers.delete(provider.id) end)
    assert {:ok, prepared} = Providers.fish_audio_config(provider.id)
    assert prepared.timeout_ms == 240_000
    assert prepared.config.model == "s2-pro"
    assert prepared.config.reference_id == "snake-speaker"
    assert prepared.config.top_p == 0.3

    assert {:ok, overlaid} =
             Providers.fish_audio_config(provider.id, %{"reference_id" => "agent-reference"})

    assert overlaid.config.reference_id == "agent-reference"
    assert overlaid.config.model == "s2-pro"
    assert overlaid.provider_id == provider.id
    assert overlaid.provider_name == provider.name
  end
end
