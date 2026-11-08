defmodule Synapsis.InworldSpeechConfigFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Config.Store
  alias Synapsis.Provider.Speech.Inworld
  alias Synapsis.{Credentials, Providers}

  test "current UUID rename connection referenced key and complete raw settings survive pure preparation" do
    tracer = trace_preparation()

    settings = %{
      "voiceId" => " Saved Voice ",
      "modelId" => " saved-custom-model ",
      "temperature" => 0.8,
      "base_url" => "https://saved-snake.example.test/options///",
      "baseUrl" => "https://saved-camel.example.test/options///",
      "api_key" => "saved-option-key",
      "apiKey" => "saved-camel-option-key",
      "timeout_ms" => 75_000,
      "timeoutMs" => 60_000,
      "max_bytes" => 65_536,
      "operator_note" => "Keep every advanced source spelling",
      "advanced" => %{"unknown" => ["one", "two"], "nested" => %{"value" => 7}}
    }

    {provider, credential} = saved(settings)
    id = provider.id
    assert {:ok, ^id} = Ecto.UUID.cast(id)
    assert {:ok, initial} = Providers.inworld_speech_config(id)

    assert initial == %{
             provider_id: id,
             provider_name: provider.name,
             timeout_ms: 30_000,
             config: %{
               api_key: "initial-inworld-contract-fixture",
               base_url: "https://Saved.Example/custom",
               voice_id: "Saved Voice",
               model_id: "saved-custom-model",
               temperature: 0.8,
               max_bytes: 65_536
             }
           }

    name = "current-inworld-contract-#{Ecto.UUID.generate()}"
    root = "https://Current.Example/tenant///"

    current_settings =
      settings |> Map.put("voiceId", " Current Voice ") |> Map.put("temperature", 1.1)

    assert {:ok, _} =
             Providers.update(id, %{name: name, base_url: root, config: current_settings})

    assert {:ok, _} =
             Credentials.update(credential.id, %{key: "current-inworld-contract-fixture"})

    assert :ok = Store.reload(:provider)
    assert {:ok, reopened} = Providers.get(id)
    assert reopened.name == name
    assert reopened.credential_id == credential.id
    assert reopened.api_key_encrypted == "current-inworld-contract-fixture"
    assert reopened.config == current_settings
    assert {:ok, by_name} = Providers.get_by_name(name)
    assert by_name.id == id
    before_prepare = File.read!(Store.file_path(:provider))

    assert {:ok, current} = Providers.inworld_speech_config(id)

    assert current == %{
             initial
             | provider_name: name,
               config: %{
                 initial.config
                 | api_key: "current-inworld-contract-fixture",
                   base_url: "https://Current.Example/tenant",
                   voice_id: "Current Voice",
                   temperature: 1.1
               }
           }

    assert {:ok, overlaid} =
             Providers.inworld_speech_config(id, %{
               "voice_id" => " Agent Voice ",
               "timeout_ms" => 45_000,
               "max_bytes" => 131_072,
               "base_url" => "https://agent-snake.example.test/options",
               "baseUrl" => "https://agent-camel.example.test/options",
               "api_key" => "agent-option-key",
               "apiKey" => "agent-camel-option-key"
             })

    assert overlaid == %{
             current
             | timeout_ms: 45_000,
               config: %{current.config | voice_id: "Agent Voice", max_bytes: 131_072}
           }

    request = %{text: "  Current UUID speech.\n你好  ", target: :audio_file, timeout_ms: 12_345}
    assert {:ok, built} = Inworld.build_request(request, overlaid.config)
    assert built.url == "https://Current.Example/tenant/tts/v1/voice:stream"
    assert built.timeout_ms === 12_345

    assert built.body == %{
             "text" => "  Current UUID speech.\n你好  ",
             "voiceId" => "Agent Voice",
             "modelId" => "saved-custom-model",
             "temperature" => 1.1,
             "audioConfig" => %{"audioEncoding" => "MP3"}
           }

    assert_saved(id, name, root, credential.id, current_settings)
    assert File.read!(Store.file_path(:provider)) == before_prepare
    assert :ok = Store.reload(:provider)
    assert_saved(id, name, root, credential.id, current_settings)
    assert File.read!(Store.file_path(:provider)) == before_prepare
    assert_no_http(tracer)
  end

  for {spelling, settings} <- [
        {"camel",
         %{"voiceId" => " Saved Voice ", "modelId" => " custom-model ", "temperature" => 0.75}},
        {"snake",
         %{"voice_id" => " Saved Voice ", "model_id" => " custom-model ", "temperature" => 0.75}}
      ] do
    @settings settings
    test "saved #{spelling} settings resolve before partial Agent overlays" do
      tracer = trace_preparation()
      {provider, credential} = saved(@settings)
      assert {:ok, prepared} = Providers.inworld_speech_config(provider.id, %{})

      assert prepared == %{
               provider_id: provider.id,
               provider_name: provider.name,
               timeout_ms: 30_000,
               config: %{
                 api_key: "initial-inworld-contract-fixture",
                 base_url: "https://Saved.Example/custom",
                 voice_id: "Saved Voice",
                 model_id: "custom-model",
                 temperature: 0.75,
                 max_bytes: 16 * 1024 * 1024
               }
             }

      assert {:ok, overlaid} =
               Providers.inworld_speech_config(provider.id, %{
                 voice_id: " Overlay Voice ",
                 temperature: 1.2
               })

      assert overlaid == %{
               prepared
               | config: %{prepared.config | voice_id: "Overlay Voice", temperature: 1.2}
             }

      assert_saved(provider.id, provider.name, provider.base_url, credential.id, @settings)
      assert_no_http(tracer)
    end
  end

  test "saved canonical aliases win by presence while untouched raw spellings remain exact" do
    tracer = trace_preparation()

    settings = %{
      "voice_id" => " Chosen Voice ",
      "voiceId" => " Alias Voice ",
      "model_id" => " chosen-custom-model ",
      "modelId" => " alias-custom-model ",
      "temperature" => 1,
      "advanced" => %{"all" => [1, 2, 3]}
    }

    {provider, credential} = saved(settings)
    assert :ok = Store.reload(:provider)
    bytes = File.read!(Store.file_path(:provider))
    assert {:ok, prepared} = Providers.inworld_speech_config(provider.id, %{})
    assert prepared.config.voice_id == "Chosen Voice"
    assert prepared.config.model_id == "chosen-custom-model"
    assert prepared.config.temperature === 1

    # Source raw config has the deliberately narrower camel-only boundary.
    assert Inworld.resolve_config(%{"providers" => %{"inworld" => settings}}) == %{
             base_url: "https://api.inworld.ai",
             voice_id: "Alias Voice",
             model_id: "alias-custom-model",
             temperature: 1
           }

    assert {:ok, partial} = Providers.inworld_speech_config(provider.id, %{"temperature" => 0.6})
    assert partial == %{prepared | config: %{prepared.config | temperature: 0.6}}
    assert_saved(provider.id, provider.name, provider.base_url, credential.id, settings)
    assert File.read!(Store.file_path(:provider)) == bytes
    assert_no_http(tracer)
  end

  for {name, overlay, voice, model} <- [
        {"snake string",
         %{
           "voice_id" => " Snake String Voice ",
           :voice_id => "Snake Atom Voice",
           "voiceId" => "Camel String Voice",
           :voiceId => "Camel Atom Voice",
           "model_id" => " snake-string-model ",
           :model_id => "snake-atom-model",
           "modelId" => "camel-string-model",
           :modelId => "camel-atom-model"
         }, "Snake String Voice", "snake-string-model"},
        {"snake atom",
         %{
           :voice_id => " Snake Atom Voice ",
           "voiceId" => "Camel String Voice",
           :voiceId => "Camel Atom Voice",
           :model_id => " snake-atom-model ",
           "modelId" => "camel-string-model",
           :modelId => "camel-atom-model"
         }, "Snake Atom Voice", "snake-atom-model"},
        {"camel string",
         %{
           "voiceId" => " Camel String Voice ",
           :voiceId => "Camel Atom Voice",
           "modelId" => " camel-string-model ",
           :modelId => "camel-atom-model"
         }, "Camel String Voice", "camel-string-model"},
        {"camel atom", %{voiceId: " Camel Atom Voice ", modelId: " camel-atom-model "},
         "Camel Atom Voice", "camel-atom-model"}
      ] do
    @overlay overlay
    @voice voice
    @model model
    test "host projection uses #{name} before later alias spellings" do
      tracer = trace_preparation()
      settings = %{"voice_id" => "Saved Voice", "model_id" => "saved-model", "temperature" => 0.8}
      {provider, credential} = saved(settings)
      assert {:ok, prepared} = Providers.inworld_speech_config(provider.id, @overlay)
      assert prepared.config.voice_id == @voice
      assert prepared.config.model_id == @model
      assert prepared.config.temperature == 0.8
      assert prepared.config.base_url == "https://Saved.Example/custom"
      assert prepared.timeout_ms == 30_000
      assert_saved(provider.id, provider.name, provider.base_url, credential.id, settings)
      assert_no_http(tracer)
    end
  end

  test "present blank canonical saved values normalize before nonblank camel aliases" do
    tracer = trace_preparation()

    settings = %{
      "voice_id" => " \t ",
      "voiceId" => "Alias Voice",
      "model_id" => "\uFEFF\u00A0",
      "modelId" => "alias-model"
    }

    {provider, credential} = saved(settings)
    assert {:ok, prepared} = Providers.inworld_speech_config(provider.id)
    assert prepared.config.voice_id == "Sarah"
    assert prepared.config.model_id == "inworld-tts-1.5-max"
    assert_saved(provider.id, provider.name, provider.base_url, credential.id, settings)
    assert_no_http(tracer)
  end

  defp saved(settings) do
    assert {:ok, credential} =
             Credentials.create(%{
               name: "inworld-contract-credential-#{Ecto.UUID.generate()}",
               key: "initial-inworld-contract-fixture"
             })

    on_exit(fn -> Credentials.delete(credential.id) end)

    assert {:ok, provider} =
             Providers.create(%{
               name: "my-inworld-contract-#{Ecto.UUID.generate()}",
               type: "inworld_speech",
               preset: "inworld-speech",
               base_url: "https://Saved.Example/custom///",
               credential_id: credential.id,
               config: settings
             })

    on_exit(fn -> Providers.delete(provider.id) end)
    {provider, credential}
  end

  defp assert_saved(id, name, root, credential_id, config) do
    assert {:ok, toml} = Toml.decode(File.read!(Store.file_path(:provider)))
    persisted = Enum.find(toml["providers"], &(&1["id"] == id))

    assert Map.take(persisted, ~w(id name type preset base_url credential_id config)) == %{
             "id" => id,
             "name" => name,
             "type" => "inworld_speech",
             "preset" => "inworld-speech",
             "base_url" => root,
             "credential_id" => credential_id,
             "config" => config
           }

    assert {:ok, saved} = Providers.get(id)
    assert saved.config == config
  end

  defp trace_preparation do
    Code.ensure_loaded!(Inworld)
    Code.ensure_loaded!(Req)

    functions = [
      {Inworld, :synthesize, 2},
      {Inworld, :synthesize_telephony, 2},
      {Inworld, :list_voices, 2},
      {Req, :request, 1},
      {Req, :request, 2}
    ]

    tracer = spawn(fn -> trace_loop([]) end)
    for mfa <- functions, do: :erlang.trace_pattern(mfa, true, [:local])
    caller = self()
    :erlang.trace(caller, true, [:call, :set_on_spawn, {:tracer, tracer}])

    on_exit(fn ->
      if Process.alive?(caller), do: :erlang.trace(caller, false, [:all])
      for mfa <- functions, do: :erlang.trace_pattern(mfa, false, [:local])
      send(tracer, :stop)
    end)

    tracer
  end

  defp assert_no_http(tracer) do
    barrier = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^barrier}, 5_000
    token = make_ref()
    send(tracer, {:snapshot, self(), token})
    assert_receive {:inworld_prepared_calls, ^token, []}, 5_000
  end

  defp trace_loop(calls) do
    receive do
      {:trace, _pid, :call, {module, function, _args}} ->
        trace_loop([{module, function} | calls])

      {:snapshot, caller, token} ->
        send(caller, {:inworld_prepared_calls, token, Enum.reverse(calls)})
        trace_loop(calls)

      :stop ->
        :ok
    end
  end
end
