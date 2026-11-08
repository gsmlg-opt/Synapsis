defmodule Synapsis.VydraSpeechProviderFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Config.Store
  alias Synapsis.Provider.Registry
  alias Synapsis.{Credentials, Models, ProviderConfig, Providers}

  test "Vydra Speech is an explicit editable TTS-only preset without LLM suggestions or seeds" do
    assert "vydra_speech" in ProviderConfig.valid_types()

    assert %{
             name: "vydra-speech",
             label: "Vydra Speech",
             type: "vydra_speech",
             base_url: "https://www.vydra.ai/api/v1",
             base_url_editable: true,
             discover_models: false
           } = Enum.find(Providers.preset_providers(), &(&1.name == "vydra-speech"))

    assert Providers.speech_capabilities(%{type: "vydra_speech"}) == [:tts]
    assert Providers.speech_only?(%{type: "vydra_speech"})

    original = Store.list(:provider)
    original_ids = MapSet.new(original, & &1["id"])

    on_exit(fn ->
      Store.list(:provider)
      |> Enum.reject(&MapSet.member?(original_ids, &1["id"]))
      |> Enum.each(&Providers.delete(&1["id"]))
    end)

    assert :ok = Providers.seed_defaults()
    assert {:ok, providers} = Providers.list()
    refute Enum.any?(providers, &(&1.name == "vydra-speech"))
    for record <- original, do: assert({:ok, ^record} = Store.get(:provider, record["id"]))
  end

  test "saved arbitrary name UUID aliases current credential and updates survive TOML reload" do
    assert {:ok, credential} =
             Credentials.create(%{
               name: "vydra-speech-credential-#{Ecto.UUID.generate()}",
               key: "ordinary-vydra-fixture"
             })

    on_exit(fn -> Credentials.delete(credential.id) end)
    name = "my-ordinary-vydra-voice-#{Ecto.UUID.generate()}"

    config = %{
      "model" => " Vydra/elevenlabs/custom ",
      "voiceId" => " saved-Rachel-custom ",
      "max_bytes" => 8192
    }

    assert {:ok, provider} =
             Providers.create(%{
               name: name,
               type: "vydra_speech",
               preset: "vydra-speech",
               credential_id: credential.id,
               config: config
             })

    on_exit(fn -> Providers.delete(provider.id) end)
    id = provider.id
    assert {:ok, ^id} = Ecto.UUID.cast(id)
    assert {:ok, ^provider} = Providers.get(id)
    assert {:ok, ^provider} = Providers.get_by_name(name)
    assert provider.config == config
    assert Providers.speech_capabilities(provider) == [:tts]
    assert Providers.speech_only?(provider)
    assert Providers.model_suggestions(provider) == []
    assert {:ok, []} = Models.list(provider_id: id)
    assert {:ok, runtime} = Providers.runtime_config(name)
    assert runtime.provider_id == id
    assert runtime.provider_name == name
    assert runtime.type == "vydra_speech"
    assert runtime.base_url == "https://www.vydra.ai/api/v1"
    # This checks current saved credential resolution, not transport/auth behavior.
    assert runtime.api_key == "ordinary-vydra-fixture"
    assert runtime_value(runtime, "model") == " Vydra/elevenlabs/custom "
    assert runtime_value(runtime, "voiceId") == " saved-Rachel-custom "
    assert runtime[:max_bytes] == 8192
    assert {:ok, ^runtime} = Registry.get(name)

    updated_config = %{
      "model" => "vydra/elevenlabs/updated",
      "voice_id" => "saved-host-alias",
      "max_bytes" => 8192
    }

    endpoint = "https://speech.example.test/custom/v8"
    assert {:ok, updated} = Providers.update(id, %{base_url: endpoint, config: updated_config})
    assert {:ok, ^updated} = Providers.get(id)
    assert {:ok, toml} = Toml.decode(File.read!(Store.file_path(:provider)))
    assert persisted = Enum.find(toml["providers"], &(&1["id"] == id))
    assert persisted["name"] == name
    assert persisted["type"] == "vydra_speech"
    assert persisted["preset"] == "vydra-speech"
    assert persisted["base_url"] == endpoint
    assert persisted["credential_id"] == credential.id
    assert persisted["config"] == updated_config

    assert {:ok, _} = Credentials.update(credential.id, %{key: "current-vydra-fixture"})
    assert :ok = Store.reload(:provider)
    assert {:ok, reloaded} = Providers.get(id)
    assert reloaded.id == id
    assert reloaded.name == name
    assert reloaded.type == "vydra_speech"
    assert reloaded.preset == "vydra-speech"
    assert reloaded.credential_id == credential.id
    assert reloaded.config == updated_config
    assert {:ok, ^reloaded} = Providers.get_by_name(name)
    assert {:ok, runtime} = Providers.runtime_config(name)
    assert runtime.provider_id == id
    assert runtime.provider_name == name
    assert runtime.type == "vydra_speech"
    assert runtime.base_url == endpoint
    assert runtime.api_key == "current-vydra-fixture"
    assert runtime_value(runtime, "model") == "vydra/elevenlabs/updated"
    assert runtime_value(runtime, "voice_id") == "saved-host-alias"
    assert runtime[:max_bytes] == 8192
    assert {:ok, ^runtime} = Registry.get(name)
    assert Providers.model_suggestions(reloaded) == []
    assert {:ok, []} = Models.list(provider_id: id)
  end

  defp runtime_value(runtime, source) do
    Enum.find_value(runtime, fn {key, value} -> if to_string(key) == source, do: value end)
  end
end
