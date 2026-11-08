defmodule Synapsis.XiaomiSpeechProviderFunctionalTest do
  use ExUnit.Case, async: false
  alias Synapsis.Config.Store
  alias Synapsis.Provider.{Registry, Speech.Xiaomi}
  alias Synapsis.{Credentials, Models, ProviderConfig, Providers}

  test "formal Xiaomi MiMo editable preset is speech only and static without automatic discovery" do
    assert "xiaomi_speech" in ProviderConfig.valid_types()

    assert %{
             name: "xiaomi-speech",
             label: "Xiaomi MiMo",
             type: "xiaomi_speech",
             base_url: "https://api.xiaomimimo.com/v1",
             base_url_editable: true,
             discover_models: false
           } = Enum.find(Providers.preset_providers(), &(&1.name == "xiaomi-speech"))

    assert Providers.default_base_url("xiaomi_speech") == "https://api.xiaomimimo.com/v1"
    assert Providers.speech_capabilities(%{type: "xiaomi_speech"}) == [:tts]
    assert Providers.speech_only?(%{type: "xiaomi_speech"})
    original = Store.list(:provider)
    original_ids = MapSet.new(original, & &1["id"])
    original_xiaomi = Enum.filter(original, &(&1["type"] == "xiaomi_speech"))

    on_exit(fn ->
      Store.list(:provider)
      |> Enum.reject(&MapSet.member?(original_ids, &1["id"]))
      |> Enum.each(&Providers.delete(&1["id"]))
    end)

    assert :ok = Providers.seed_defaults()
    assert Enum.filter(Store.list(:provider), &(&1["type"] == "xiaomi_speech")) == original_xiaomi
    for record <- original, do: assert({:ok, ^record} = Store.get(:provider, record["id"]))
  end

  test "saved UUID current route and referenced credential preserve full advanced TOML" do
    config = %{
      "modelId" => " custom-saved-model ",
      "speakerVoiceId" => " Saved Voice ",
      "voice" => "lower-priority",
      "voice_id" => "snake-secondary",
      "format" => " WAV ",
      "style" => " Calm\nclear narration. ",
      "timeoutMs" => 60_000,
      "timeout_ms" => 75_000,
      "max_bytes" => 65_536,
      "response_format" => "preserve-opaque-format",
      "output_format" => "preserve-output",
      "instructions" => "preserve-advanced-instructions",
      "operator_note" => "Keep complete settings",
      "advanced" => %{"custom" => ["one", "two"]}
    }

    {provider, credential} = saved(config)
    id = provider.id
    assert {:ok, ^id} = Ecto.UUID.cast(id)
    assert {:ok, ^provider} = Providers.get_by_name(provider.name)
    assert {:ok, prepared} = Providers.xiaomi_speech_config(id)

    assert prepared == %{
             provider_id: id,
             provider_name: provider.name,
             timeout_ms: 30_000,
             config: %{
               api_key: "initial-xiaomi-fixture",
               base_url: "https://Saved.Example/custom/v3",
               model: "custom-saved-model",
               voice: "Saved Voice",
               format: "wav",
               style: "Calm\nclear narration.",
               max_bytes: 65_536
             }
           }

    assert {:ok, built} =
             Xiaomi.build_request(
               %{text: "Saved line.", target: :audio_file, timeout_ms: 21_123.75},
               prepared.config
             )

    assert built.timeout_ms == 21_123
    endpoint = "https://Current.Example/tenant/prefix////"
    updated_config = Map.put(config, "speakerVoiceId", " Current Voice ")
    assert {:ok, _} = Providers.update(id, %{base_url: endpoint, config: updated_config})
    assert {:ok, _} = Credentials.update(credential.id, %{key: "current-xiaomi-fixture"})
    assert {:ok, toml} = Toml.decode(File.read!(Store.file_path(:provider)))
    assert persisted = Enum.find(toml["providers"], &(&1["id"] == id))

    assert Map.take(persisted, ~w(id name type preset base_url credential_id config)) == %{
             "id" => id,
             "name" => provider.name,
             "type" => "xiaomi_speech",
             "preset" => "xiaomi-speech",
             "base_url" => endpoint,
             "credential_id" => credential.id,
             "config" => updated_config
           }

    assert :ok = Store.reload(:provider)
    assert {:ok, current_provider} = Providers.get(id)
    assert current_provider.config == updated_config
    assert current_provider.credential_id == credential.id
    assert {:ok, current} = Providers.xiaomi_speech_config(id)

    assert current == %{
             prepared
             | config: %{
                 prepared.config
                 | api_key: "current-xiaomi-fixture",
                   base_url: "https://Current.Example/tenant/prefix",
                   voice: "Current Voice"
               }
           }

    assert {:ok, runtime} = Providers.runtime_config(provider.name)
    assert runtime.provider_id == id
    assert runtime.provider_name == provider.name
    assert runtime.api_key == "current-xiaomi-fixture"
    assert runtime.base_url == endpoint
    assert {:ok, ^runtime} = Registry.get(provider.name)
    assert Providers.model_suggestions(current_provider) == []
    assert {:ok, []} = Models.list(provider_id: id)

    assert {:ok, overlay} =
             Providers.xiaomi_speech_config(id, %{
               "model_id" => " mimo-v2.5-tts-voicedesign ",
               "voice_id" => " Agent Voice ",
               "format" => " MP3 ",
               "style" => " Agent style ",
               "timeout_ms" => 45_000,
               "max_bytes" => 131_072,
               "api_key" => "agent-opaque-setting",
               "base_url" => "https://agent-opaque-setting.example"
             })

    assert overlay == %{
             current
             | timeout_ms: 45_000,
               config: %{
                 current.config
                 | model: "mimo-v2.5-tts-voicedesign",
                   voice: "Agent Voice",
                   format: "mp3",
                   style: "Agent style",
                   max_bytes: 131_072
               }
           }

    assert {:ok, built} =
             Xiaomi.build_request(
               %{text: "Tool line.", target: :audio_file, timeout_ms: 75_000},
               overlay.config
             )

    assert built.timeout_ms == 75_000
    assert {:ok, unchanged} = Providers.get(id)
    assert unchanged.config == updated_config
    assert unchanged.base_url == endpoint
    assert unchanged.credential_id == credential.id
  end

  for {settings, model, voice} <- [
        {%{
           "model_id" => " custom-snake ",
           "speaker_voice_id" => " Snake Voice ",
           "voice_id" => "secondary"
         }, "custom-snake", "Snake Voice"},
        {%{"model" => " mimo-v2.5-tts-voicedesign ", "speaker_voice" => " Mia "},
         "mimo-v2.5-tts-voicedesign", "Mia"},
        {%{"modelId" => " custom-source ", "voiceId" => " Dean "}, "custom-source", "Dean"}
      ] do
    @settings settings
    @model model
    @voice voice
    test "saved aliases normalize before a partial Agent overlay #{model}" do
      {provider, _credential} =
        saved(Map.merge(@settings, %{"format" => " WAV ", "style" => " Saved style "}))

      assert {:ok, prepared} = Providers.xiaomi_speech_config(provider.id)
      assert prepared.timeout_ms == 30_000
      assert prepared.config.model == @model
      assert prepared.config.voice == @voice
      assert prepared.config.format == "wav"
      assert prepared.config.style == "Saved style"
      assert prepared.config.max_bytes == 16 * 1024 * 1024
      refute Map.has_key?(prepared.config, :timeout_ms)

      assert {:ok, overlaid} =
               Providers.xiaomi_speech_config(provider.id, %{"voice_id" => " Agent Voice "})

      assert overlaid == %{prepared | config: %{prepared.config | voice: "Agent Voice"}}
      assert {:ok, saved_provider} = Providers.get(provider.id)

      assert saved_provider.config ==
               Map.merge(@settings, %{"format" => " WAV ", "style" => " Saved style "})
    end
  end

  test "current saved connection and canonical Agent overlay produce exact real HTTP without extra fields" do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)

    {provider, credential} =
      saved(%{
        "modelId" => "mimo-v2.5-tts-voicedesign",
        "speakerVoiceId" => "Mia",
        "format" => "wav",
        "style" => " Saved style ",
        "timeoutMs" => 60_000,
        "max_bytes" => 65_536,
        "instructions" => "opaque advanced setting"
      })

    endpoint = Gaoxy.Test.url(fixture, "/tenant/v7")
    assert {:ok, _} = Providers.update(provider.id, %{base_url: endpoint})
    assert {:ok, _} = Credentials.update(credential.id, %{key: "current-xiaomi-fixture"})

    assert {:ok, prepared} =
             Providers.xiaomi_speech_config(provider.id, %{
               "model_id" => " custom-current ",
               "voice_id" => " Current Voice ",
               "format" => " MP3 ",
               "style" => " Current style ",
               "timeout_ms" => 45_000
             })

    assert prepared.timeout_ms == 45_000
    owner = self()

    Gaoxy.Test.stub(fixture, "POST", "/tenant/v7/chat/completions", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Plug.Conn.get_req_header(conn, "api-key") == ["current-xiaomi-fixture"]

      assert Jason.decode!(raw) == %{
               "model" => "custom-current",
               "messages" => [
                 %{"role" => "user", "content" => "Current style"},
                 %{"role" => "assistant", "content" => "  Exact saved line.\n亲切  "}
               ],
               "audio" => %{"format" => "mp3", "voice" => "Current Voice"}
             }

      send(owner, :saved_xiaomi_request)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "choices" => [
            %{"message" => %{"audio" => %{"data" => "AQIDBA=="}}},
            %{"message" => %{"audio" => %{"data" => "BQYHCA=="}}}
          ],
          "usage" => %{"total_tokens" => 7}
        })
      )
    end)

    request = %{text: "  Exact saved line.\n亲切  ", target: :audio_file, timeout_ms: 75_000}
    assert {:ok, built} = Xiaomi.build_request(request, prepared.config)
    assert built.timeout_ms == 75_000

    assert {:ok,
            %{
              audio: <<1, 2, 3, 4>>,
              output_format: "mp3",
              file_extension: ".mp3",
              voice_compatible: false
            }} =
             Xiaomi.synthesize(request, prepared.config)

    assert_receive :saved_xiaomi_request, 5_000
    refute_receive :saved_xiaomi_request, 20
  end

  defp saved(config) do
    assert {:ok, credential} =
             Credentials.create(%{
               name: "xiaomi-credential-#{Ecto.UUID.generate()}",
               key: "initial-xiaomi-fixture"
             })

    on_exit(fn -> Credentials.delete(credential.id) end)

    assert {:ok, provider} =
             Providers.create(%{
               name: "arbitrary-mimo-#{Ecto.UUID.generate()}",
               type: "xiaomi_speech",
               preset: "xiaomi-speech",
               base_url: "https://Saved.Example/custom/v3",
               credential_id: credential.id,
               config: config
             })

    on_exit(fn -> Providers.delete(provider.id) end)
    {provider, credential}
  end
end
