defmodule SynapsisWeb.ProviderLive.GradiumSpeechFunctionalTest do
  use SynapsisWeb.ConnCase
  import SynapsisWeb.ReactFormHelpers

  alias Synapsis.{Config.Store, Credentials, Models, Providers}

  test "explicit Gradium Speech preset creates a saved speech provider with an editable endpoint",
       %{
         conn: conn
       } do
    credential = credential!()
    name = unique_name("gradium-create")
    cleanup_provider(name)
    endpoint = "https://speech-ui.example.test/custom/v7"

    {:ok, view, _html} = live(conn, ~p"/settings/providers/new")
    preset = ~s(button[phx-click="select_preset"][phx-value-name="gradium-speech"])
    assert has_element?(view, preset, "Gradium Speech")
    assert has_element?(view, preset, "Text to speech")
    view |> element(preset) |> render_click()
    assert has_element?(view, "input[name='base_url'][value='https://api.gradium.ai']")

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
    id = provider.id
    assert {:ok, ^id} = Ecto.UUID.cast(id)
    assert provider.type == "gradium_speech"
    assert provider.preset == "gradium-speech"
    assert provider.base_url == endpoint
    assert provider.credential_id == credential.id
    assert Providers.speech_only?(provider)
    assert Providers.speech_capabilities(provider) == [:tts]
    assert {:ok, []} = Models.list(provider_id: id)

    assert {:ok, toml} = Toml.decode(File.read!(Store.file_path(:provider)))
    assert persisted = Enum.find(toml["providers"], &(&1["id"] == id))
    assert persisted["name"] == name
    assert persisted["type"] == "gradium_speech"
    assert persisted["preset"] == "gradium-speech"
    assert persisted["base_url"] == endpoint
    assert persisted["credential_id"] == credential.id
    assert :ok = Store.reload(:provider)
    assert {:ok, reloaded} = Providers.get(id)
    assert reloaded.id == id
    assert reloaded.name == name
    assert reloaded.type == "gradium_speech"
    assert reloaded.preset == "gradium-speech"
    assert reloaded.credential_id == credential.id
    assert reloaded.base_url == endpoint
    assert {:ok, runtime} = Providers.runtime_config(name)
    assert runtime.provider_id == id
    assert runtime.provider_name == name
    assert runtime.type == "gradium_speech"
    assert runtime.base_url == endpoint

    {:ok, index, _html} = live(conn, ~p"/settings/providers")
    assert has_element?(index, "a[href='/settings/providers/#{id}']", name)
    assert render(index) =~ "Text to speech"
  end

  test "speech detail keeps saved identity type capability and voice while editing the connection",
       %{
         conn: conn
       } do
    credential = credential!()
    replacement = credential!()
    name = unique_name("gradium-detail")
    cleanup_provider(name)

    assert {:ok, provider} =
             Providers.create(%{
               name: name,
               type: "gradium_speech",
               preset: "gradium-speech",
               base_url: "https://api.gradium.ai",
               credential_id: credential.id,
               config: %{"voice_id" => "LFZvm12tW_z0xfGo", "max_bytes" => 8192}
             })

    {:ok, view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
    assert html =~ "Text to speech"
    assert html =~ "tts.provider"
    assert html =~ "saved provider name"
    assert has_element?(view, "#speech-provider-reference", name)
    assert has_element?(view, "input[name='base_url'][value='https://api.gradium.ai']")
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
    assert has_element?(view, "#speech-provider-reference", name)
    assert {:ok, updated} = Providers.get(provider.id)
    assert updated.id == provider.id
    assert updated.name == name
    assert updated.type == "gradium_speech"
    assert updated.preset == "gradium-speech"
    assert updated.base_url == endpoint
    assert updated.credential_id == replacement.id
    assert updated.enabled
    assert updated.config == provider.config
    assert Providers.speech_capabilities(updated) == [:tts]
    assert {:ok, []} = Models.list(provider_id: provider.id)

    assert :ok = Store.reload(:provider)
    assert {:ok, reloaded} = Providers.get(provider.id)
    assert reloaded.id == provider.id
    assert reloaded.name == name
    assert reloaded.type == "gradium_speech"
    assert reloaded.preset == "gradium-speech"
    assert reloaded.config == provider.config
    assert {:ok, runtime} = Providers.runtime_config(name)
    assert runtime.provider_id == provider.id
    assert runtime.provider_name == name
    assert runtime.type == "gradium_speech"
    assert runtime.base_url == endpoint
    assert runtime.voice_id == "LFZvm12tW_z0xfGo"
    assert runtime.max_bytes == 8192

    {:ok, reopened, html} = live(conn, ~p"/settings/providers/#{provider.id}")
    assert html =~ "Text to speech"
    assert has_element?(reopened, "#speech-provider-reference", name)
    assert has_element?(reopened, "input[name='base_url'][value='#{endpoint}']")

    assert has_element?(
             reopened,
             "select[name='credential_id'] option[value='#{replacement.id}'][selected]"
           )
  end

  defp credential! do
    assert {:ok, credential} =
             Credentials.create(%{
               name: unique_name("gradium-ui-credential"),
               key: "ordinary-gradium-ui-fixture"
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
