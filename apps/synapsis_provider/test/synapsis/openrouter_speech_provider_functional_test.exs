defmodule Synapsis.OpenRouterSpeechProviderFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Config.Store
  alias Synapsis.Provider.Registry
  alias Synapsis.{Credentials, Models, ProviderConfig, Providers}

  test "OpenRouter Speech is an explicit editable TTS-only preset without seeded LLM models" do
    assert "openrouter_speech" in ProviderConfig.valid_types()

    assert %{
             name: "openrouter-speech",
             label: "OpenRouter Speech",
             type: "openrouter_speech",
             base_url: "https://openrouter.ai/api/v1",
             base_url_editable: true,
             discover_models: false
           } = Enum.find(Providers.preset_providers(), &(&1.name == "openrouter-speech"))

    assert Providers.speech_capabilities(%{type: "openrouter_speech"}) == [:tts]
    assert Providers.speech_only?(%{type: "openrouter_speech"})
    original = Store.list(:provider)
    original_ids = MapSet.new(original, & &1["id"])

    on_exit(fn ->
      Store.list(:provider)
      |> Enum.reject(&MapSet.member?(original_ids, &1["id"]))
      |> Enum.each(&Providers.delete(&1["id"]))
    end)

    assert :ok = Providers.seed_defaults()
    assert {:ok, providers} = Providers.list()
    refute Enum.any?(providers, &(&1.name == "openrouter-speech"))

    for record <- original do
      assert {:ok, ^record} = Store.get(:provider, record["id"])
    end
  end

  test "saved UUID name aliases routing and current credential survive update and TOML reload" do
    assert {:ok, credential} =
             Credentials.create(%{
               name: "router-speech-credential-#{Ecto.UUID.generate()}",
               key: "ordinary-router-fixture"
             })

    on_exit(fn -> Credentials.delete(credential.id) end)
    name = "my-ordinary-voice-#{Ecto.UUID.generate()}"

    routing = %{
      "order" => ["ordinary-route", "second-route"],
      "allow_fallbacks" => true,
      "options" => %{"openai" => %{"instructions" => "Speak warmly."}}
    }

    config = %{
      "modelId" => "google/gemini-3.1-flash-tts-preview",
      "speakerVoice" => "Kore",
      "voiceId" => "saved-secondary-voice",
      "responseFormat" => "pcm",
      "speed" => 0.9,
      "provider" => routing,
      "max_bytes" => 8192
    }

    assert {:ok, provider} =
             Providers.create(%{
               name: name,
               type: "openrouter_speech",
               preset: "openrouter-speech",
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
    assert runtime.type == "openrouter_speech"
    assert runtime.base_url == "https://openrouter.ai/api/v1"
    assert runtime.api_key == "ordinary-router-fixture"
    assert runtime[:provider] == routing
    assert runtime[:max_bytes] == 8192
    assert runtime_value(runtime, "modelId") == "google/gemini-3.1-flash-tts-preview"
    assert runtime_value(runtime, "speakerVoice") == "Kore"
    assert runtime_value(runtime, "voiceId") == "saved-secondary-voice"
    assert runtime_value(runtime, "responseFormat") == "pcm"
    assert {:ok, ^runtime} = Registry.get(name)

    updated_config =
      config
      |> Map.put("speakerVoice", "ordinary-updated-voice")
      |> Map.put("provider", Map.put(routing, "order", ["updated-route"]))

    endpoint = "https://speech.example/router/v7"
    assert {:ok, updated} = Providers.update(id, %{base_url: endpoint, config: updated_config})
    assert {:ok, ^updated} = Providers.get(id)
    assert {:ok, toml} = Toml.decode(File.read!(Store.file_path(:provider)))
    assert persisted = Enum.find(toml["providers"], &(&1["id"] == id))
    assert persisted["name"] == name
    assert persisted["type"] == "openrouter_speech"
    assert persisted["preset"] == "openrouter-speech"
    assert persisted["base_url"] == endpoint
    assert persisted["credential_id"] == credential.id
    assert persisted["config"] == updated_config

    assert {:ok, _} = Credentials.update(credential.id, %{key: "current-router-fixture"})
    assert :ok = Store.reload(:provider)
    assert {:ok, reloaded} = Providers.get(id)
    assert reloaded.id == id
    assert reloaded.name == name
    assert reloaded.type == "openrouter_speech"
    assert reloaded.preset == "openrouter-speech"
    assert reloaded.credential_id == credential.id
    assert reloaded.config == updated_config
    assert {:ok, ^reloaded} = Providers.get_by_name(name)
    assert {:ok, runtime} = Providers.runtime_config(name)
    assert runtime.provider_id == id
    assert runtime.provider_name == name
    assert runtime.type == "openrouter_speech"
    assert runtime.base_url == endpoint
    assert runtime.api_key == "current-router-fixture"
    assert runtime[:provider] == updated_config["provider"]
    assert runtime[:max_bytes] == 8192
    assert runtime_value(runtime, "modelId") == "google/gemini-3.1-flash-tts-preview"
    assert runtime_value(runtime, "speakerVoice") == "ordinary-updated-voice"
    assert runtime_value(runtime, "voiceId") == "saved-secondary-voice"
    assert runtime_value(runtime, "responseFormat") == "pcm"
    assert {:ok, ^runtime} = Registry.get(name)
    assert {:ok, []} = Models.list(provider_id: id)
  end

  # Providers currently interns existing top-level atoms only; either existing
  # key representation retains the exact saved alias and nested string map.
  defp runtime_value(runtime, source) do
    Enum.find_value(runtime, fn {key, value} -> if to_string(key) == source, do: value end)
  end
end
