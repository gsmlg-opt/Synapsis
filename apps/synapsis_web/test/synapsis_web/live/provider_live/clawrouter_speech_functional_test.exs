defmodule SynapsisWeb.ProviderLive.ClawRouterSpeechFunctionalTest do
  use SynapsisWeb.ConnCase
  import SynapsisWeb.ReactFormHelpers

  alias Synapsis.{Config.Store, Credentials, Models, Providers}
  alias SynapsisWeb.ToolResultView

  @models ["openai/tts-1"]
  @voices ~w(alloy echo fable onyx nova shimmer)

  test "explicit preset create, connection edit, TOML reload and reopen retain speech identity",
       %{conn: conn} do
    credential = credential!()
    replacement = credential!()
    name = "my-clawrouter-speech-#{Ecto.UUID.generate()}"
    cleanup_provider(name)
    endpoint = "https://speech-ui.example.test/ClawRouter/tenant/v1"
    {:ok, view, _} = live(conn, ~p"/settings/providers/new")
    preset = ~s(button[phx-click="select_preset"][phx-value-name="clawrouter-speech"])
    assert has_element?(view, preset, "ClawRouter")
    assert has_element?(view, preset, "Text to speech")
    view |> element(preset) |> render_click()

    assert has_element?(
             view,
             "input[name='base_url'][value='https://clawrouter.openclaw.ai/v1']"
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
    assert provider.type == "clawrouter_speech"
    assert provider.preset == "clawrouter-speech"
    assert provider.credential_id == credential.id
    assert provider.base_url == endpoint
    assert Providers.speech_capabilities(provider) == [:tts]
    assert {:ok, []} = Models.list(provider_id: id)

    config = %{
      "modelId" => " openai/tts-1 ",
      "speakerVoiceId" => " echo ",
      "responseFormat" => " AaC ",
      "speed" => 1.25,
      "timeoutMs" => 60_000,
      "max_bytes" => 65_536,
      "advanced_fixture" => %{"preserve" => true, "labels" => ["one", "two"]}
    }

    assert {:ok, _} = Providers.update(id, %{config: config})
    {:ok, detail, html} = live(conn, ~p"/settings/providers/#{id}")
    assert html =~ "Text to speech"
    assert html =~ "tts.provider"
    assert has_element?(detail, "#speech-provider-reference", name)
    assert has_element?(detail, "#clawrouter-speech-model option[value='openai/tts-1'][selected]")
    assert has_element?(detail, "#clawrouter-speech-voice option[value='echo'][selected]")
    endpoint = "https://speech-edit.example.test/ClawRouter/tenant/v1"

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
    assert reloaded.type == "clawrouter_speech"
    assert reloaded.credential_id == replacement.id
    {:ok, reopened, _} = live(conn, ~p"/settings/providers/#{id}")
    assert has_element?(reopened, "#speech-provider-reference", name)

    assert has_element?(
             reopened,
             "#clawrouter-speech-model option[value='openai/tts-1'][selected]"
           )

    assert has_element?(reopened, "#clawrouter-speech-voice option[value='echo'][selected]")

    assert has_element?(
             reopened,
             "select[name='credential_id'] option[value='#{replacement.id}'][selected]"
           )
  end

  test "one model and six static voice choices save explicitly and preserve advanced source config",
       %{conn: conn} do
    credential = credential!()
    name = "clawrouter-selection-#{Ecto.UUID.generate()}"
    cleanup_provider(name)
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    owner = self()

    for {method, path} <- [
          {"GET", "/Custom/ClawRouter/v1/models"},
          {"GET", "/Custom/ClawRouter/v1/voices"},
          {"GET", "/Custom/ClawRouter/v1/catalog"},
          {"POST", "/Custom/ClawRouter/v1/audio/speech"}
        ] do
      Gaoxy.Test.stub(fixture, method, path, fn conn ->
        send(owner, :clawrouter_ui_catalog_or_synthesis)
        Plug.Conn.resp(conn, 200, "{}")
      end)
    end

    config = %{
      "model" => " openai/tts-1 ",
      "modelId" => "openai/tts-1",
      "model_id" => "openai/tts-1",
      "speakerVoice" => " echo ",
      "speakerVoiceId" => "fable",
      "speaker_voice" => "onyx",
      "speaker_voice_id" => "nova",
      "voice" => "alloy",
      "voiceId" => "shimmer",
      "voice_id" => "alloy",
      "speed" => 1.25,
      "responseFormat" => " AAC ",
      "timeoutMs" => 60_000,
      "max_bytes" => 65_536,
      "advanced_fixture" => %{"preserve" => true, "labels" => ["one", "two"]}
    }

    assert {:ok, provider} =
             Providers.create(%{
               name: name,
               type: "clawrouter_speech",
               preset: "clawrouter-speech",
               base_url: Gaoxy.Test.url(fixture, "/Custom/ClawRouter/v1"),
               credential_id: credential.id,
               config: config
             })

    assert {:ok, _} = Credentials.update(credential.id, %{key: "current-clawrouter-ui-fixture"})
    assert {:ok, provider} = Providers.get(provider.id)
    {:ok, view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
    assert html =~ "ClawRouter"

    assert has_element?(
             view,
             "#clawrouter-speech-form[phx-change='clawrouter_selection_change'][phx-submit='clawrouter_selection_save']"
           )

    assert has_element?(view, "select#clawrouter-speech-model[name='model']")
    assert has_element?(view, "select#clawrouter-speech-voice[name='voice']")
    assert has_element?(view, "#clawrouter-speech-model option[value='openai/tts-1'][selected]")
    assert has_element?(view, "#clawrouter-speech-voice option[value='echo'][selected]")

    for model <- @models,
        do: assert(has_element?(view, "#clawrouter-speech-model option[value='#{model}']"))

    for voice <- @voices,
        do: assert(has_element?(view, "#clawrouter-speech-voice option[value='#{voice}']"))

    assert option_values(view, "#clawrouter-speech-model option") == @models
    assert option_values(view, "#clawrouter-speech-voice option") == @voices
    assert has_element?(view, "#clawrouter-save-speech", "Save speech settings")
    refute has_element?(view, "[phx-click='refresh_models']")
    refute has_element?(view, "[phx-click='toggle_chat']")

    view
    |> form("#clawrouter-speech-form", %{"model" => "openai/tts-1", "voice" => "shimmer"})
    |> render_change()

    assert {:ok, ^provider} = Providers.get(provider.id)
    assert has_element?(view, "#clawrouter-speech-voice option[value='shimmer'][selected]")

    view
    |> form("#clawrouter-speech-form", %{"model" => "openai/tts-1", "voice" => "shimmer"})
    |> render_submit()

    expected = %{
      "model" => "openai/tts-1",
      "voice" => "shimmer",
      "speed" => 1.25,
      "responseFormat" => " AAC ",
      "timeoutMs" => 60_000,
      "max_bytes" => 65_536,
      "advanced_fixture" => %{"preserve" => true, "labels" => ["one", "two"]}
    }

    assert {:ok, saved} = Providers.get(provider.id)
    assert saved.config == expected
    assert saved.id == provider.id
    assert saved.name == name
    assert saved.credential_id == credential.id
    assert saved.base_url == provider.base_url
    assert saved.api_key_encrypted == "current-clawrouter-ui-fixture"
    assert {:ok, []} = Models.list(provider_id: provider.id)
    assert {:ok, toml} = Toml.decode(File.read!(Store.file_path(:provider)))
    assert Enum.find(toml["providers"], &(&1["id"] == provider.id))["config"] == expected
    assert :ok = Store.reload(:provider)
    assert {:ok, reloaded} = Providers.get(provider.id)
    assert reloaded.config == expected
    assert reloaded.api_key_encrypted == "current-clawrouter-ui-fixture"
    {:ok, reopened, _} = live(conn, ~p"/settings/providers/#{provider.id}")

    assert has_element?(
             reopened,
             "#clawrouter-speech-model option[value='openai/tts-1'][selected]"
           )

    assert has_element?(reopened, "#clawrouter-speech-voice option[value='shimmer'][selected]")
    assert option_values(reopened, "#clawrouter-speech-model option") == @models
    assert option_values(reopened, "#clawrouter-speech-voice option") == @voices

    reopened
    |> form("#clawrouter-speech-form", %{"model" => "openai/tts-1", "voice" => "fable"})
    |> render_submit()

    assert {:ok, second} = Providers.get(provider.id)
    assert second.config == %{expected | "voice" => "fable"}
    assert second.credential_id == credential.id
    assert second.api_key_encrypted == "current-clawrouter-ui-fixture"
    assert :ok = Store.reload(:provider)
    {:ok, second_reopened, _} = live(conn, ~p"/settings/providers/#{provider.id}")

    assert has_element?(
             second_reopened,
             "#clawrouter-speech-voice option[value='fable'][selected]"
           )

    assert {:ok, []} = Models.list(provider_id: provider.id)
    refute_receive :clawrouter_ui_catalog_or_synthesis, 50
  end

  test "AAC delivery descriptor projects an audio MIME and exact download filename" do
    descriptor = %{
      "uri" =>
        "synapsis-media://audio/879e0dc0bd6975d2ea69cb21e342b49af304213823721ecd70876274994f6d09.aac",
      "sha256" => "879e0dc0bd6975d2ea69cb21e342b49af304213823721ecd70876274994f6d09",
      "byte_size" => 1_250,
      "mime_type" => "audio/aac",
      "format" => "aac"
    }

    delivery = %{
      "version" => 1,
      "session_id" => "c4132950-88b4-4d47-890d-607eac337340",
      "id" => "d1387fa7-1619-42f4-a4c3-40c968336340"
    }

    expected = %{
      type: "audio",
      src:
        "/api/media/audio/c4132950-88b4-4d47-890d-607eac337340/d1387fa7-1619-42f4-a4c3-40c968336340",
      mediaType: "audio/aac",
      filename: "audio.aac"
    }

    assert {:ok, ^expected} = ToolResultView.audio_delivery(descriptor, delivery)

    # Use the native projection constructor so the shared display assertion
    # exercises its actual versioned result envelope.
    assert {:ok, part} =
             Synapsis.Agent.Tools.ResultProjection.to_part(
               "ordinary-clawrouter-aac",
               %{
                 is_error: false,
                 content: [%{type: "text", text: "(spoken) Ordinary ClawRouter AAC."}],
                 details: %{"mediaDescriptor" => descriptor, "mediaDelivery" => delivery}
               },
               tool_name: "synapsis::tts"
             )

    assert ToolResultView.present(part).blocks == [
             %{type: "text", text: "(spoken) Ordinary ClawRouter AAC."},
             expected
           ]
  end

  defp option_values(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("value")
  end

  defp credential! do
    assert {:ok, credential} =
             Credentials.create(%{
               name: "clawrouter-ui-credential-#{Ecto.UUID.generate()}",
               key: "ordinary-clawrouter-ui-fixture"
             })

    on_exit(fn -> Credentials.delete(credential.id) end)
    credential
  end

  defp cleanup_provider(name) do
    on_exit(fn ->
      case Providers.get_by_name(name) do
        {:ok, provider} -> Providers.delete(provider.id)
        {:error, :not_found} -> :ok
      end
    end)
  end
end
