defmodule Synapsis.XAISpeechProviderFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Config.Store
  alias Synapsis.Provider.Registry
  alias Synapsis.{Credentials, Models, ProviderConfig, Providers}

  test "xAI Speech has an explicit editable TTS-only provider preset" do
    assert "xai_speech" in ProviderConfig.valid_types()

    assert %{
             name: "xai-speech",
             label: "xAI Speech",
             type: "xai_speech",
             base_url: "https://api.x.ai/v1",
             base_url_editable: true,
             discover_models: false
           } =
             Enum.find(Providers.preset_providers(), &(&1.name == "xai-speech"))

    assert Providers.speech_capabilities(%{type: "xai_speech"}) == [:tts]
    assert Providers.speech_only?(%{type: "xai_speech"})
  end

  test "saved UUID name credential and speech settings survive update and TOML reload" do
    assert {:ok, credential} =
             Credentials.create(%{
               name: "xai-speech-credential-#{Ecto.UUID.generate()}",
               key: "ordinary-xai-fixture"
             })

    on_exit(fn -> Credentials.delete(credential.id) end)
    name = "xai-speech-#{Ecto.UUID.generate()}"

    config = %{
      "voice_id" => "sal",
      "language" => "pt-br",
      "speed" => 0.9,
      "response_format" => "wav",
      "max_bytes" => 8192
    }

    assert {:ok, provider} =
             Providers.create(%{
               name: name,
               type: "xai_speech",
               preset: "xai-speech",
               credential_id: credential.id,
               config: config
             })

    on_exit(fn -> Providers.delete(provider.id) end)
    id = provider.id
    assert {:ok, ^id} = Ecto.UUID.cast(id)
    assert {:ok, ^provider} = Providers.get(id)
    assert {:ok, ^provider} = Providers.get_by_name(name)
    assert Providers.speech_capabilities(provider) == [:tts]
    assert Providers.model_suggestions(provider) == []
    assert {:ok, []} = Models.list(provider_id: id)
    assert {:ok, runtime} = Providers.runtime_config(name)
    assert runtime.provider_id == id
    assert runtime.provider_name == name
    assert runtime.type == "xai_speech"
    assert runtime.base_url == "https://api.x.ai/v1"
    assert runtime.api_key == "ordinary-xai-fixture"

    assert Map.take(runtime, [:voice_id, :language, :speed, :response_format, :max_bytes]) ==
             %{
               voice_id: "sal",
               language: "pt-br",
               speed: 0.9,
               response_format: "wav",
               max_bytes: 8192
             }

    assert {:ok, ^runtime} = Registry.get(name)

    updated_config = Map.merge(config, %{"voice_id" => "rex", "language" => "de", "speed" => 1.1})
    endpoint = "https://speech.example/custom/v7"
    assert {:ok, updated} = Providers.update(id, %{base_url: endpoint, config: updated_config})
    assert {:ok, ^updated} = Providers.get(id)
    assert {:ok, toml} = Toml.decode(File.read!(Store.file_path(:provider)))
    assert persisted = Enum.find(toml["providers"], &(&1["id"] == id))
    assert persisted["name"] == name
    assert persisted["type"] == "xai_speech"
    assert persisted["preset"] == "xai-speech"
    assert persisted["base_url"] == endpoint
    assert persisted["credential_id"] == credential.id
    assert Map.take(persisted["config"], Map.keys(updated_config)) == updated_config

    assert {:ok, _} = Credentials.update(credential.id, %{key: "current-xai-fixture"})
    assert :ok = Store.reload(:provider)
    assert {:ok, reloaded} = Providers.get(id)
    assert reloaded.name == name
    assert reloaded.type == "xai_speech"
    assert reloaded.preset == "xai-speech"
    assert reloaded.credential_id == credential.id
    assert {:ok, runtime} = Providers.runtime_config(name)
    assert runtime.provider_id == id
    assert runtime.provider_name == name
    assert runtime.type == "xai_speech"
    assert runtime.base_url == endpoint
    assert runtime.api_key == "current-xai-fixture"

    assert Map.take(runtime, [:voice_id, :language, :speed, :response_format, :max_bytes]) ==
             %{
               voice_id: "rex",
               language: "de",
               speed: 1.1,
               response_format: "wav",
               max_bytes: 8192
             }

    assert {:ok, ^runtime} = Registry.get(name)
    assert {:ok, []} = Models.list(provider_id: id)
  end
end
