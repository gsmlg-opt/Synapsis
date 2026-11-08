defmodule SynapsisWeb.ProviderLive.GoogleSpeechFunctionalTest do
  use SynapsisWeb.ConnCase
  import SynapsisWeb.ReactFormHelpers
  alias Synapsis.{Config.Store, Credentials, Models, Providers}

  @models ~w(gemini-3.8-flash-tts gemini-3.8-flash-lite-tts gemini-3.1-flash-tts-preview gemini-2.5-flash-preview-tts gemini-2.5-pro-preview-tts)
  @voices ~w(Zephyr Puck Charon Kore Fenrir Leda Orus Aoede Callirrhoe Autonoe Enceladus Iapetus Umbriel Algieba Despina Erinome Algenib Rasalgethi Laomedeia Achernar Alnilam Schedar Gacrux Pulcherrima Achird Zubenelgenubi Vindemiatrix Sadachbia Sadaltager Sulafat)

  test "generic explicit preset create, edit, TOML reload and reopen preserve speech identity", %{
    conn: conn
  } do
    credential = credential!()
    replacement = credential!()
    name = "my-google-speech-#{Ecto.UUID.generate()}"
    cleanup_provider(name)
    endpoint = "https://speech-ui.example.test/google/v7"
    {:ok, view, _} = live(conn, ~p"/settings/providers/new")
    preset = ~s(button[phx-click="select_preset"][phx-value-name="google-speech"])
    assert has_element?(view, preset, "Google Speech")
    assert has_element?(view, preset, "Text to speech")
    view |> element(preset) |> render_click()

    assert has_element?(
             view,
             "input[name='base_url'][value='https://generativelanguage.googleapis.com/v1beta']"
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
    assert provider.type == "google_speech"
    assert provider.preset == "google-speech"
    assert provider.credential_id == credential.id
    assert provider.base_url == endpoint
    assert Providers.speech_capabilities(provider) == [:tts]
    assert {:ok, []} = Models.list(provider_id: id)

    config = %{
      "model" => "fixture-custom-tts",
      "voiceName" => "Current Custom Voice",
      "audioProfile" => "Warm",
      "speakerName" => "Guide",
      "speakers" => [
        %{"speaker" => "First", "voice" => "Puck"},
        %{"speaker" => "Second", "voice" => "Kore"}
      ],
      "promptTemplate" => "audio-profile-v1",
      "personaPrompt" => "Calm",
      "timeout_ms" => 60_000,
      "max_bytes" => 8_192
    }

    assert {:ok, _} = Providers.update(id, %{config: config})
    {:ok, detail, html} = live(conn, ~p"/settings/providers/#{id}")
    assert html =~ "Text to speech"
    assert html =~ "tts.provider"
    assert has_element?(detail, "#speech-provider-reference", name)
    assert has_element?(detail, "#google-speech-model[value='fixture-custom-tts']")
    assert has_element?(detail, "#google-speech-voice[value='Current Custom Voice']")
    endpoint = "https://speech-edit.example.test/google/v8"

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
    assert reloaded.type == "google_speech"
    assert reloaded.credential_id == replacement.id
    {:ok, reopened, _} = live(conn, ~p"/settings/providers/#{id}")
    assert has_element?(reopened, "#speech-provider-reference", name)
    assert has_element?(reopened, "#google-speech-model[value='fixture-custom-tts']")
    assert has_element?(reopened, "#google-speech-voice[value='Current Custom Voice']")

    assert has_element?(
             reopened,
             "select[name='credential_id'] option[value='#{replacement.id}'][selected]"
           )
  end

  test "static five model and thirty voice suggestions change explicitly, save narrowly and reopen",
       %{conn: conn} do
    credential = credential!()
    name = "google-selection-#{Ecto.UUID.generate()}"
    cleanup_provider(name)
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    owner = self()

    for {method, path} <- [
          {"GET", "/v1beta/models"},
          {"GET", "/v1beta/voices"},
          {"POST", "/v1beta/interactions"},
          {"POST", "/v1beta/models/gemini-3.1-flash-tts-preview:generateContent"}
        ] do
      Gaoxy.Test.stub(fixture, method, path, fn conn ->
        send(owner, :unexpected_google_catalog_or_synthesis)
        Plug.Conn.resp(conn, 200, "{}")
      end)
    end

    config = %{
      "model" => "fixture-custom-tts",
      "modelId" => "old-model-alias",
      "model_id" => "old-model-snake",
      "voiceName" => "Current Custom Voice",
      "voice" => "old-voice-alias",
      "voice_name" => "old-voice-snake",
      "audioProfile" => "Warm",
      "speakerName" => "Guide",
      "speakers" => [
        %{"speaker" => "First", "voice" => "Puck"},
        %{"speaker" => "Second", "voice" => "Kore"}
      ],
      "promptTemplate" => "audio-profile-v1",
      "personaPrompt" => "Calm",
      "timeout_ms" => 60_000,
      "max_bytes" => 8_192
    }

    assert {:ok, provider} =
             Providers.create(%{
               name: name,
               type: "google_speech",
               preset: "google-speech",
               base_url: Gaoxy.Test.url(fixture, "/v1beta"),
               credential_id: credential.id,
               config: config
             })

    {:ok, view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
    assert html =~ "Google Speech voice"

    assert has_element?(
             view,
             "#google-speech-form[phx-change='google_selection_change'][phx-submit='google_selection_save']"
           )

    assert has_element?(
             view,
             "#google-speech-model[name='model'][list='google-speech-models'][value='fixture-custom-tts']"
           )

    assert has_element?(
             view,
             "#google-speech-voice[name='voice_name'][list='google-speech-voices'][value='Current Custom Voice']"
           )

    for model <- @models,
        do: assert(has_element?(view, "#google-speech-models option[value='#{model}']"))

    for voice <- @voices,
        do: assert(has_element?(view, "#google-speech-voices option[value='#{voice}']"))

    assert length(
             view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#google-speech-models option")
             |> LazyHTML.to_tree()
           ) == 5

    assert length(
             view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#google-speech-voices option")
             |> LazyHTML.to_tree()
           ) == 30

    assert has_element?(view, "#google-save-selection", "Save speech settings")
    refute has_element?(view, "[phx-click='refresh_models']")
    refute has_element?(view, "[phx-click='toggle_chat']")

    view
    |> form("#google-speech-form", %{
      "model" => "gemini-3.8-flash-lite-tts",
      "voice_name" => "Aoede"
    })
    |> render_change()

    assert {:ok, ^provider} = Providers.get(provider.id)
    assert has_element?(view, "#google-speech-model[value='gemini-3.8-flash-lite-tts']")
    assert has_element?(view, "#google-speech-voice[value='Aoede']")

    view
    |> form("#google-speech-form", %{
      "model" => "gemini-3.8-flash-lite-tts",
      "voice_name" => "Aoede"
    })
    |> render_submit()

    expected =
      config
      |> Map.drop(~w(model model_id modelId voiceName voice_name voice))
      |> Map.put("model", "gemini-3.8-flash-lite-tts")
      |> Map.put("voice_name", "Aoede")

    assert {:ok, saved} = Providers.get(provider.id)
    assert saved.config == expected
    assert saved.id == provider.id
    assert saved.name == name
    assert saved.credential_id == credential.id
    assert saved.base_url == provider.base_url
    assert {:ok, []} = Models.list(provider_id: provider.id)
    assert {:ok, toml} = Toml.decode(File.read!(Store.file_path(:provider)))
    assert Enum.find(toml["providers"], &(&1["id"] == provider.id))["config"] == expected
    assert :ok = Store.reload(:provider)
    {:ok, reopened, _} = live(conn, ~p"/settings/providers/#{provider.id}")
    assert has_element?(reopened, "#google-speech-model[value='gemini-3.8-flash-lite-tts']")
    assert has_element?(reopened, "#google-speech-voice[value='Aoede']")

    reopened
    |> form("#google-speech-form", %{
      "model" => "custom-future-tts",
      "voice_name" => "Another Custom Voice"
    })
    |> render_submit()

    assert {:ok, custom} = Providers.get(provider.id)

    assert custom.config == %{
             expected
             | "model" => "custom-future-tts",
               "voice_name" => "Another Custom Voice"
           }

    refute_receive :unexpected_google_catalog_or_synthesis, 50
  end

  defp credential! do
    assert {:ok, credential} =
             Credentials.create(%{
               name: "google-ui-credential-#{Ecto.UUID.generate()}",
               key: "ordinary-google-ui-fixture"
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
