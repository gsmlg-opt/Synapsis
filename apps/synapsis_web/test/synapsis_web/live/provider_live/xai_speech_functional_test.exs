defmodule SynapsisWeb.ProviderLive.XAISpeechFunctionalTest do
  use SynapsisWeb.ConnCase
  import SynapsisWeb.ReactFormHelpers

  alias Synapsis.{Config.Store, Credentials, Providers}

  test "explicit xAI Speech preset creates a speech provider with an editable endpoint", %{
    conn: conn
  } do
    credential = credential!()
    name = unique_name("speech-create")
    cleanup_provider(name)
    endpoint = "https://speech-ui.example.test/custom/v7"

    {:ok, view, _html} = live(conn, ~p"/settings/providers/new")
    preset = ~s(button[phx-click="select_preset"][phx-value-name="xai-speech"])
    assert has_element?(view, preset, "xAI Speech")
    assert has_element?(view, preset, "Text to speech")
    view |> element(preset) |> render_click()

    assert has_element?(view, "input[name='base_url'][value='https://api.x.ai/v1']")

    assert has_element?(
             view,
             "select[name='credential_id'] option[value='#{credential.id}']",
             credential.name
           )

    react_form_submit(view, "create-provider-form", %{
      "name" => name,
      "base_url" => endpoint,
      "credential_id" => credential.id
    })

    assert %{"info" => "Provider created"} = assert_redirected(view, ~p"/settings/providers")
    assert {:ok, provider} = Providers.get_by_name(name)
    assert provider.type == "xai_speech"
    assert provider.preset == "xai-speech"
    assert provider.base_url == endpoint
    assert provider.credential_id == credential.id
    assert Providers.speech_only?(provider)
    assert Providers.speech_capabilities(provider) == [:tts]
    assert provider.config["model_catalog_migrated"] == true

    assert {:ok, toml} = Toml.decode(File.read!(Store.file_path(:provider)))
    assert persisted = Enum.find(toml["providers"], &(&1["id"] == provider.id))
    assert persisted["type"] == "xai_speech"
    assert persisted["preset"] == "xai-speech"
    assert persisted["base_url"] == endpoint
    assert persisted["credential_id"] == credential.id
    assert :ok = Store.reload(:provider)
    assert {:ok, reloaded} = Providers.get(provider.id)
    assert reloaded.type == "xai_speech"
    assert reloaded.credential_id == credential.id
    assert reloaded.base_url == endpoint
    assert {:ok, runtime} = Providers.runtime_config(name)
    assert runtime.provider_id == provider.id
    assert runtime.provider_name == name
    assert runtime.type == "xai_speech"
    assert runtime.base_url == endpoint

    {:ok, index, _html} = live(conn, ~p"/settings/providers")
    assert has_element?(index, "a[href='/settings/providers/#{provider.id}']", name)
    assert render(index) =~ "Text to speech"
  end

  test "speech detail preserves its type and capability while editing the connection", %{
    conn: conn
  } do
    credential = credential!()
    replacement = credential!()
    name = unique_name("speech-detail")
    cleanup_provider(name)

    assert {:ok, provider} =
             Providers.create(%{
               name: name,
               type: "xai_speech",
               preset: "xai-speech",
               base_url: "https://api.x.ai/v1",
               credential_id: credential.id,
               config: %{"model_catalog_migrated" => true}
             })

    {:ok, view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
    assert html =~ "Text to speech"
    assert html =~ "tts.provider"
    assert html =~ "saved provider name"
    assert has_element?(view, "#speech-provider-reference", provider.name)
    assert has_element?(view, "input[name='base_url'][value='https://api.x.ai/v1']")
    refute has_element?(view, "[phx-click='refresh_models']")
    refute has_element?(view, "[phx-click='toggle_chat']")
    refute html =~ "Manage Models"

    endpoint = "https://speech-edit.example.test/custom/v8"

    html =
      react_form_submit(view, "edit-provider-form", %{
        "base_url" => endpoint,
        "credential_id" => replacement.id,
        "enabled" => true
      })

    assert html =~ "Provider updated"
    assert html =~ "Text to speech"
    assert has_element?(view, "#speech-provider-reference", provider.name)
    assert {:ok, updated} = Providers.get(provider.id)
    assert updated.type == "xai_speech"
    assert updated.preset == "xai-speech"
    assert updated.base_url == endpoint
    assert updated.credential_id == replacement.id
    assert updated.enabled
    assert Providers.speech_capabilities(updated) == [:tts]

    assert :ok = Store.reload(:provider)
    assert {:ok, runtime} = Providers.runtime_config(name)
    assert runtime.provider_id == provider.id
    assert runtime.type == "xai_speech"
    assert runtime.base_url == endpoint

    {:ok, reopened, html} = live(conn, ~p"/settings/providers/#{provider.id}")
    assert html =~ "Text to speech"
    assert has_element?(reopened, "#speech-provider-reference", provider.name)
    assert has_element?(reopened, "input[name='base_url'][value='#{endpoint}']")

    assert has_element?(
             reopened,
             "select[name='credential_id'] option[value='#{replacement.id}'][selected]"
           )
  end

  defp credential! do
    assert {:ok, credential} =
             Credentials.create(%{
               name: unique_name("speech-ui-credential"),
               key: "ordinary-speech-ui-fixture"
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

  defp unique_name(prefix), do: prefix <> "-" <> Ecto.UUID.generate()
end
