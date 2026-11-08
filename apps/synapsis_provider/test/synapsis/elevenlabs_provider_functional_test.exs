defmodule Synapsis.ElevenLabsProviderFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.{ProviderConfig, Providers}
  alias Synapsis.Provider.Registry

  test "a speech provider persists through the existing provider store and resolves its runtime identity" do
    name = "elevenlabs-#{System.unique_integer([:positive])}"

    assert {:ok, provider} =
             Providers.create(%{
               name: name,
               type: "elevenlabs",
               api_key_encrypted: "ordinary-speech-fixture",
               config: %{
                 "voice_id" => "ordinaryVoice12345",
                 "model_id" => "eleven_multilingual_v2"
               }
             })

    on_exit(fn -> Providers.delete(provider.id) end)
    assert "elevenlabs" in ProviderConfig.valid_types()
    assert {:ok, ^provider} = Providers.get(provider.id)
    assert {:ok, ^provider} = Providers.get_by_name(name)
    assert {:ok, runtime} = Providers.runtime_config(name)
    assert runtime.type == "elevenlabs"
    assert runtime.provider_id == provider.id
    assert runtime.provider_name == name
    assert runtime.base_url == "https://api.elevenlabs.io"
    assert runtime.voice_id == "ordinaryVoice12345"
    assert runtime.model_id == "eleven_multilingual_v2"
    assert {:ok, ^runtime} = Registry.get(name)

    assert {:ok, updated} =
             Providers.update(provider.id, %{
               config: Map.put(provider.config, "voice_id", "updatedVoice12345")
             })

    assert {:ok, ^updated} = Providers.get(provider.id)
    assert {:ok, %{voice_id: "updatedVoice12345"}} = Providers.runtime_config(name)
  end
end
