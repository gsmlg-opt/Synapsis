defmodule Synapsis.GradiumSpeechProviderFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Config.Store
  alias Synapsis.Provider.Registry
  alias Synapsis.{Credentials, Models, ProviderConfig, Providers}

  test "Gradium Speech has an explicit editable TTS-only provider preset" do
    assert "gradium_speech" in ProviderConfig.valid_types()

    assert %{
             name: "gradium-speech",
             label: "Gradium Speech",
             type: "gradium_speech",
             base_url: "https://api.gradium.ai",
             base_url_editable: true,
             discover_models: false
           } =
             Enum.find(Providers.preset_providers(), &(&1.name == "gradium-speech"))

    assert Providers.speech_capabilities(%{type: "gradium_speech"}) == [:tts]
    assert Providers.speech_only?(%{type: "gradium_speech"})
    original = Store.list(:provider)
    original_ids = MapSet.new(original, & &1["id"])

    on_exit(fn ->
      Store.list(:provider)
      |> Enum.reject(&MapSet.member?(original_ids, &1["id"]))
      |> Enum.each(&Providers.delete(&1["id"]))
    end)

    assert :ok = Providers.seed_defaults()
    assert {:ok, providers} = Providers.list()
    refute Enum.any?(providers, &(&1.name == "gradium-speech"))

    for record <- original do
      assert {:ok, ^record} = Store.get(:provider, record["id"])
    end
  end

  test "saved UUID name credential and Gradium voice survive update and TOML reload" do
    assert {:ok, credential} =
             Credentials.create(%{
               name: "gradium-speech-credential-#{Ecto.UUID.generate()}",
               key: "ordinary-gradium-fixture"
             })

    on_exit(fn -> Credentials.delete(credential.id) end)
    name = "gradium-speech-#{Ecto.UUID.generate()}"
    config = %{"voice_id" => "LFZvm12tW_z0xfGo", "max_bytes" => 8192}

    assert {:ok, provider} =
             Providers.create(%{
               name: name,
               type: "gradium_speech",
               preset: "gradium-speech",
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
    assert runtime.type == "gradium_speech"
    assert runtime.base_url == "https://api.gradium.ai"
    assert runtime.api_key == "ordinary-gradium-fixture"

    assert Map.take(runtime, [:voice_id, :max_bytes]) == %{
             voice_id: "LFZvm12tW_z0xfGo",
             max_bytes: 8192
           }

    assert {:ok, ^runtime} = Registry.get(name)

    updated_config = Map.put(config, "voice_id", "Eu9iL_CYe8N-Gkx_")
    endpoint = "https://speech.example/custom/v7"
    assert {:ok, updated} = Providers.update(id, %{base_url: endpoint, config: updated_config})
    assert {:ok, ^updated} = Providers.get(id)
    assert {:ok, toml} = Toml.decode(File.read!(Store.file_path(:provider)))
    assert persisted = Enum.find(toml["providers"], &(&1["id"] == id))
    assert persisted["name"] == name
    assert persisted["type"] == "gradium_speech"
    assert persisted["preset"] == "gradium-speech"
    assert persisted["base_url"] == endpoint
    assert persisted["credential_id"] == credential.id
    assert Map.take(persisted["config"], Map.keys(updated_config)) == updated_config

    assert {:ok, _} = Credentials.update(credential.id, %{key: "current-gradium-fixture"})
    assert :ok = Store.reload(:provider)
    assert {:ok, reloaded} = Providers.get(id)
    assert reloaded.id == id
    assert reloaded.name == name
    assert reloaded.type == "gradium_speech"
    assert reloaded.preset == "gradium-speech"
    assert reloaded.credential_id == credential.id
    assert reloaded.config == updated_config
    assert {:ok, ^reloaded} = Providers.get_by_name(name)
    assert {:ok, runtime} = Providers.runtime_config(name)
    assert runtime.provider_id == id
    assert runtime.provider_name == name
    assert runtime.type == "gradium_speech"
    assert runtime.base_url == endpoint
    assert runtime.api_key == "current-gradium-fixture"

    assert Map.take(runtime, [:voice_id, :max_bytes]) == %{
             voice_id: "Eu9iL_CYe8N-Gkx_",
             max_bytes: 8192
           }

    assert {:ok, ^runtime} = Registry.get(name)
    assert {:ok, []} = Models.list(provider_id: id)
  end
end
