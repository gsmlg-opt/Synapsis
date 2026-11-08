defmodule SynapsisWeb.ProviderLive.XiaomiSpeechFunctionalTest do
  use SynapsisWeb.ConnCase
  import SynapsisWeb.ReactFormHelpers
  alias Synapsis.{Config.Store, Credentials, Models, Providers}

  @models ~w(mimo-v2.5-tts mimo-v2.5-tts-voicedesign)
  @voices ~w(mimo_default default_zh default_en Mia Chloe Milo Dean)

  test "generic explicit preset create, edit, TOML reload and reopen preserve speech identity", %{
    conn: conn
  } do
    credential = credential!()
    replacement = credential!()
    name = "my-xiaomi-speech-#{Ecto.UUID.generate()}"
    cleanup_provider(name)
    endpoint = "https://speech-ui.example.test/xiaomi/v7"
    {:ok, view, _} = live(conn, ~p"/settings/providers/new")
    preset = ~s(button[phx-click="select_preset"][phx-value-name="xiaomi-speech"])
    assert has_element?(view, preset, "Xiaomi MiMo")
    assert has_element?(view, preset, "Text to speech")
    view |> element(preset) |> render_click()

    assert has_element?(
             view,
             "input[name='base_url'][value='https://api.xiaomimimo.com/v1']"
           )

    react_form_submit(view, "create-provider-form", %{
      "name" => name,
      "base_url" => endpoint,
      "credential_id" => credential.id
    })

    assert %{"info" => "Provider created"} = assert_redirected(view, ~p"/settings/providers")
    assert {:ok, provider} = Providers.get_by_name(name)
    id = provider.id
    assert {:ok, ^id} = Ecto.UUID.cast(id)
    assert provider.type == "xiaomi_speech"
    assert provider.preset == "xiaomi-speech"
    assert provider.credential_id == credential.id
    assert provider.base_url == endpoint
    assert Providers.speech_capabilities(provider) == [:tts]
    assert {:ok, []} = Models.list(provider_id: id)

    config = %{
      "modelId" => "fixture-custom-tts",
      "speakerVoiceId" => "Current Custom Voice",
      "format" => " WaV ",
      "style" => "A clear storyteller.",
      "timeoutMs" => 60_000,
      "max_bytes" => 65_536,
      "advanced_fixture" => %{"preserve" => true, "labels" => ["one", "two"]}
    }

    assert {:ok, _} = Providers.update(id, %{config: config})
    {:ok, detail, html} = live(conn, ~p"/settings/providers/#{id}")
    assert html =~ "Text to speech"
    assert html =~ "tts.provider"
    assert has_element?(detail, "#speech-provider-reference", name)
    assert has_element?(detail, "#xiaomi-speech-model[value='fixture-custom-tts']")
    assert has_element?(detail, "#xiaomi-speech-voice[value='Current Custom Voice']")
    endpoint = "https://speech-edit.example.test/xiaomi/v8"

    html =
      react_form_submit(detail, "edit-provider-form", %{
        "base_url" => endpoint,
        "credential_id" => replacement.id,
        "enabled" => true
      })

    assert html =~ "Provider updated"
    assert {:ok, updated} = Providers.get(id)
    assert updated.config == config
    assert updated.credential_id == replacement.id
    assert updated.base_url == endpoint
    assert :ok = Store.reload(:provider)
    assert {:ok, reloaded} = Providers.get(id)
    assert reloaded.config == config
    assert reloaded.name == name
    assert reloaded.type == "xiaomi_speech"
    assert reloaded.credential_id == replacement.id
    {:ok, reopened, _} = live(conn, ~p"/settings/providers/#{id}")
    assert has_element?(reopened, "#speech-provider-reference", name)
    assert has_element?(reopened, "#xiaomi-speech-model[value='fixture-custom-tts']")
    assert has_element?(reopened, "#xiaomi-speech-voice[value='Current Custom Voice']")

    assert has_element?(
             reopened,
             "select[name='credential_id'] option[value='#{replacement.id}'][selected]"
           )
  end

  test "static two model and seven voice suggestions change explicitly, save narrowly and reopen",
       %{conn: conn} do
    credential = credential!()
    name = "xiaomi-selection-#{Ecto.UUID.generate()}"
    cleanup_provider(name)
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    owner = self()

    for {method, path} <- [
          {"GET", "/Custom/Xiaomi/v7/models"},
          {"GET", "/Custom/Xiaomi/v7/voices"},
          {"POST", "/Custom/Xiaomi/v7/chat/completions"}
        ] do
      Gaoxy.Test.stub(fixture, method, path, fn conn ->
        send(owner, :unexpected_xiaomi_catalog_or_synthesis)
        Plug.Conn.resp(conn, 200, "{}")
      end)
    end

    config = %{
      "model" => "fixture-custom-tts",
      "modelId" => "old-model-alias",
      "model_id" => "old-model-snake",
      "speakerVoice" => "Current Custom Voice",
      "speakerVoiceId" => "old-speaker-id",
      "speaker_voice" => "old-speaker-snake",
      "speaker_voice_id" => "old-speaker-id-snake",
      "voice" => "old-voice-alias",
      "voiceId" => "old-voice-id",
      "voice_id" => "old-voice-snake",
      "style" => "Warm and clear.",
      "format" => " WAV ",
      "timeoutMs" => 60_000,
      "max_bytes" => 65_536,
      "advanced_fixture" => %{"preserve" => true, "labels" => ["one", "two"]}
    }

    assert {:ok, provider} =
             Providers.create(%{
               name: name,
               type: "xiaomi_speech",
               preset: "xiaomi-speech",
               base_url: Gaoxy.Test.url(fixture, "/Custom/Xiaomi/v7"),
               credential_id: credential.id,
               config: config
             })

    assert {:ok, _} = Credentials.update(credential.id, %{key: "current-xiaomi-ui-fixture"})
    assert {:ok, provider} = Providers.get(provider.id)
    {:ok, view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
    assert html =~ "Xiaomi MiMo"

    assert has_element?(
             view,
             "#xiaomi-speech-form[phx-change='xiaomi_selection_change'][phx-submit='xiaomi_selection_save']"
           )

    assert has_element?(
             view,
             "#xiaomi-speech-model[name='model'][list='xiaomi-speech-models'][value='fixture-custom-tts']"
           )

    assert has_element?(
             view,
             "#xiaomi-speech-voice[name='voice'][list='xiaomi-speech-voices'][value='Current Custom Voice']"
           )

    for model <- @models,
        do: assert(has_element?(view, "#xiaomi-speech-models option[value='#{model}']"))

    for voice <- @voices,
        do: assert(has_element?(view, "#xiaomi-speech-voices option[value='#{voice}']"))

    assert length(
             view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#xiaomi-speech-models option")
             |> LazyHTML.to_tree()
           ) == 2

    assert length(
             view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#xiaomi-speech-voices option")
             |> LazyHTML.to_tree()
           ) == 7

    assert has_element?(view, "#xiaomi-save-selection", "Save speech settings")
    refute has_element?(view, "[phx-click='refresh_models']")
    refute has_element?(view, "[phx-click='toggle_chat']")

    view
    |> form("#xiaomi-speech-form", %{
      "model" => "mimo-v2.5-tts-voicedesign",
      "voice" => "Dean"
    })
    |> render_change()

    assert {:ok, ^provider} = Providers.get(provider.id)
    assert has_element?(view, "#xiaomi-speech-model[value='mimo-v2.5-tts-voicedesign']")
    assert has_element?(view, "#xiaomi-speech-voice[value='Dean']")

    view
    |> form("#xiaomi-speech-form", %{
      "model" => "mimo-v2.5-tts-voicedesign",
      "voice" => "Dean"
    })
    |> render_submit()

    expected =
      config
      |> Map.drop(
        ~w(model model_id modelId speakerVoice speakerVoiceId speaker_voice speaker_voice_id voice voiceId voice_id)
      )
      |> Map.put("model", "mimo-v2.5-tts-voicedesign")
      |> Map.put("voice", "Dean")

    assert {:ok, saved} = Providers.get(provider.id)
    assert saved.config == expected
    assert saved.id == provider.id
    assert saved.name == name
    assert saved.credential_id == credential.id
    assert saved.base_url == provider.base_url
    assert saved.api_key_encrypted == "current-xiaomi-ui-fixture"
    assert {:ok, []} = Models.list(provider_id: provider.id)
    assert {:ok, toml} = Toml.decode(File.read!(Store.file_path(:provider)))
    assert Enum.find(toml["providers"], &(&1["id"] == provider.id))["config"] == expected
    assert :ok = Store.reload(:provider)
    {:ok, reopened, _} = live(conn, ~p"/settings/providers/#{provider.id}")
    assert has_element?(reopened, "#xiaomi-speech-model[value='mimo-v2.5-tts-voicedesign']")
    assert has_element?(reopened, "#xiaomi-speech-voice[value='Dean']")

    reopened
    |> form("#xiaomi-speech-form", %{
      "model" => "custom-future-tts",
      "voice" => "Another Custom Voice"
    })
    |> render_submit()

    assert {:ok, custom} = Providers.get(provider.id)

    assert custom.config == %{
             expected
             | "model" => "custom-future-tts",
               "voice" => "Another Custom Voice"
           }

    assert custom.credential_id == credential.id
    assert custom.api_key_encrypted == "current-xiaomi-ui-fixture"
    assert :ok = Store.reload(:provider)
    assert {:ok, reloaded_custom} = Providers.get(provider.id)
    assert reloaded_custom.config == custom.config
    assert reloaded_custom.api_key_encrypted == "current-xiaomi-ui-fixture"
    {:ok, custom_reopened, _} = live(conn, ~p"/settings/providers/#{provider.id}")
    assert has_element?(custom_reopened, "#xiaomi-speech-model[value='custom-future-tts']")
    assert has_element?(custom_reopened, "#xiaomi-speech-voice[value='Another Custom Voice']")
    assert {:ok, []} = Models.list(provider_id: provider.id)

    refute_receive :unexpected_xiaomi_catalog_or_synthesis, 50
  end

  defp credential! do
    assert {:ok, credential} =
             Credentials.create(%{
               name: "xiaomi-ui-credential-#{Ecto.UUID.generate()}",
               key: "ordinary-xiaomi-ui-fixture"
             })

    on_exit(fn -> Credentials.delete(credential.id) end)
    credential
  end

  defp cleanup_provider(name) do
    on_exit(fn ->
      case Providers.get_by_name(name) do
        {:ok, p} -> Providers.delete(p.id)
        {:error, :not_found} -> :ok
      end
    end)
  end
end
