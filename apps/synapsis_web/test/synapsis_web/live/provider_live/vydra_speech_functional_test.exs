defmodule SynapsisWeb.ProviderLive.VydraSpeechFunctionalTest do
  use SynapsisWeb.ConnCase
  import SynapsisWeb.ReactFormHelpers

  alias Synapsis.{Config.Store, Credentials, Models, Providers}

  test "Vydra Speech preset creates a saved speech-only provider with editable base", %{
    conn: conn
  } do
    credential = credential!()
    name = unique_name("my-vydra-voice")
    cleanup_provider(name)
    endpoint = "https://speech-ui.example.test/custom/v7"
    {:ok, view, _html} = live(conn, ~p"/settings/providers/new")
    preset = ~s(button[phx-click="select_preset"][phx-value-name="vydra-speech"])
    assert has_element?(view, preset, "Vydra Speech")
    assert has_element?(view, preset, "Text to speech")
    view |> element(preset) |> render_click()
    assert has_element?(view, "input[name='base_url'][value='https://www.vydra.ai/api/v1']")

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
    assert provider.type == "vydra_speech"
    assert provider.preset == "vydra-speech"
    assert provider.base_url == endpoint
    assert provider.credential_id == credential.id
    assert Providers.speech_only?(provider)
    assert Providers.speech_capabilities(provider) == [:tts]
    assert Providers.model_suggestions(provider) == []
    assert {:ok, []} = Models.list(provider_id: id)
    assert {:ok, toml} = Toml.decode(File.read!(Store.file_path(:provider)))
    assert persisted = Enum.find(toml["providers"], &(&1["id"] == id))
    assert persisted["name"] == name
    assert persisted["type"] == "vydra_speech"
    assert persisted["preset"] == "vydra-speech"
    assert persisted["base_url"] == endpoint
    assert persisted["credential_id"] == credential.id
    assert :ok = Store.reload(:provider)
    assert {:ok, reloaded} = Providers.get(id)
    assert reloaded.id == id
    assert reloaded.name == name
    assert reloaded.type == "vydra_speech"
    assert reloaded.preset == "vydra-speech"
    assert reloaded.credential_id == credential.id
    assert reloaded.base_url == endpoint
    assert {:ok, runtime} = Providers.runtime_config(name)
    assert runtime.provider_id == id
    assert runtime.provider_name == name
    assert runtime.type == "vydra_speech"
    assert runtime.base_url == endpoint
    {:ok, index, _html} = live(conn, ~p"/settings/providers")
    assert has_element?(index, "a[href='/settings/providers/#{id}']", name)
    assert render(index) =~ "Text to speech"
  end

  test "generic edit and reopen preserve advanced model voice aliases and credential reference",
       %{conn: conn} do
    credential = credential!()
    replacement = credential!()
    name = unique_name("my-vydra-detail")
    cleanup_provider(name)

    config = %{
      "model" => "vydra/elevenlabs/custom",
      "voiceId" => "source-alias-voice",
      "voice_id" => "host-alias-voice",
      "max_bytes" => 8192
    }

    assert {:ok, provider} =
             Providers.create(%{
               name: name,
               type: "vydra_speech",
               preset: "vydra-speech",
               base_url: "https://www.vydra.ai/api/v1",
               credential_id: credential.id,
               config: config
             })

    {:ok, view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
    assert html =~ "Text to speech"
    assert html =~ "tts.provider"
    assert html =~ "saved provider name"
    assert has_element?(view, "#speech-provider-reference", name)
    assert has_element?(view, "input[name='base_url'][value='https://www.vydra.ai/api/v1']")
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
    assert updated.type == "vydra_speech"
    assert updated.preset == "vydra-speech"
    assert updated.base_url == endpoint
    assert updated.credential_id == replacement.id
    assert updated.enabled
    assert updated.config == config
    assert Providers.speech_capabilities(updated) == [:tts]
    assert {:ok, []} = Models.list(provider_id: provider.id)
    assert {:ok, toml} = Toml.decode(File.read!(Store.file_path(:provider)))
    assert persisted = Enum.find(toml["providers"], &(&1["id"] == provider.id))
    assert persisted["name"] == name
    assert persisted["credential_id"] == replacement.id
    assert persisted["config"] == config
    assert :ok = Store.reload(:provider)
    assert {:ok, reloaded} = Providers.get(provider.id)
    assert reloaded.id == provider.id
    assert reloaded.name == name
    assert reloaded.type == "vydra_speech"
    assert reloaded.preset == "vydra-speech"
    assert reloaded.credential_id == replacement.id
    assert reloaded.config == config
    assert {:ok, runtime} = Providers.runtime_config(name)
    assert runtime.provider_id == provider.id
    assert runtime.provider_name == name
    assert runtime.type == "vydra_speech"
    assert runtime.base_url == endpoint
    assert runtime_value(runtime, "model") == "vydra/elevenlabs/custom"
    assert runtime_value(runtime, "voiceId") == "source-alias-voice"
    assert runtime_value(runtime, "voice_id") == "host-alias-voice"
    assert runtime[:max_bytes] == 8192
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
               name: unique_name("vydra-ui-credential"),
               key: "ordinary-vydra-ui-fixture"
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

  defp runtime_value(runtime, source) do
    Enum.find_value(runtime, fn {key, value} -> if to_string(key) == source, do: value end)
  end

  defp unique_name(prefix), do: prefix <> "-" <> Ecto.UUID.generate()
end
