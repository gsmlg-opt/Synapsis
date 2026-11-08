defmodule SynapsisWeb.ProviderLive.SpeechFunctionalTest do
  use SynapsisWeb.ConnCase
  import SynapsisWeb.ReactFormHelpers

  alias Synapsis.{Config.Store, Credentials, Providers}

  test "explicit ElevenLabs preset creates a speech provider with an editable endpoint", %{
    conn: conn
  } do
    credential = credential!()
    name = unique_name("speech-create")
    cleanup_provider(name)
    endpoint = "https://speech-ui.example.test/api"

    {:ok, view, _html} = live(conn, ~p"/settings/providers/new")
    preset = ~s(button[phx-click="select_preset"][phx-value-name="elevenlabs"])
    assert has_element?(view, preset, "ElevenLabs")
    assert has_element?(view, preset, "Text to speech")
    view |> element(preset) |> render_click()

    assert has_element?(view, "input[name='base_url'][value='https://api.elevenlabs.io']")

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
    assert provider.type == "elevenlabs"
    assert provider.preset == "elevenlabs"
    assert provider.base_url == endpoint
    assert provider.credential_id == credential.id
    assert Providers.speech_only?(provider)
    assert provider.config["model_catalog_migrated"] == true

    assert {:ok, toml} = Toml.decode(File.read!(Store.file_path(:provider)))
    assert persisted = Enum.find(toml["providers"], &(&1["id"] == provider.id))
    assert persisted["type"] == "elevenlabs"
    assert persisted["base_url"] == endpoint
    assert persisted["credential_id"] == credential.id
    assert :ok = Store.reload(:provider)
    assert {:ok, reloaded} = Providers.get(provider.id)
    assert reloaded.type == "elevenlabs"
    assert reloaded.credential_id == credential.id
    assert reloaded.base_url == endpoint
    assert {:ok, runtime} = Providers.runtime_config(name)
    assert runtime.provider_id == provider.id
    assert runtime.provider_name == name
    assert runtime.type == "elevenlabs"
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
               type: "elevenlabs",
               preset: "elevenlabs",
               base_url: "https://api.elevenlabs.io",
               credential_id: credential.id,
               config: %{"model_catalog_migrated" => true}
             })

    {:ok, view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
    assert html =~ "Text to speech"
    assert html =~ "tts.provider"
    assert html =~ "saved provider name"
    assert has_element?(view, "#speech-provider-reference", provider.name)
    assert has_element?(view, "input[name='base_url'][value='https://api.elevenlabs.io']")
    refute has_element?(view, "[phx-click='refresh_models']")
    refute has_element?(view, "[phx-click='toggle_chat']")
    refute html =~ "Manage Models"

    endpoint = "https://speech-edit.example.test/vendor"

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
    assert updated.type == "elevenlabs"
    assert updated.preset == "elevenlabs"
    assert updated.base_url == endpoint
    assert updated.credential_id == replacement.id
    assert updated.enabled

    assert :ok = Store.reload(:provider)
    assert {:ok, runtime} = Providers.runtime_config(name)
    assert runtime.provider_id == provider.id
    assert runtime.type == "elevenlabs"
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

  test "explicit OpenAI Speech preset creates both speech capabilities with an editable endpoint",
       %{
         conn: conn
       } do
    credential = credential!()
    name = unique_name("openai-speech-create")
    cleanup_provider(name)
    endpoint = "https://openai-speech-ui.example.test/custom/api"

    {:ok, view, _html} = live(conn, ~p"/settings/providers/new")
    preset = ~s(button[phx-click="select_preset"][phx-value-name="openai-speech"])
    assert has_element?(view, preset, "OpenAI Speech")
    assert has_element?(view, preset, "Text to speech")
    assert has_element?(view, preset, "Speech to text")
    view |> element(preset) |> render_click()

    assert has_element?(view, "input[name='base_url'][value='https://api.openai.com']")
    assert render(view) =~ "Speech to text"

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
    assert provider.type == "openai_speech"
    assert provider.preset == "openai-speech"
    assert provider.base_url == endpoint
    assert provider.credential_id == credential.id
    assert Providers.speech_only?(provider)
    assert Providers.speech_capabilities(provider) == [:tts, :stt]
    assert provider.config["model_catalog_migrated"] == true

    assert {:ok, toml} = Toml.decode(File.read!(Store.file_path(:provider)))
    assert persisted = Enum.find(toml["providers"], &(&1["id"] == provider.id))
    assert persisted["type"] == "openai_speech"
    assert persisted["preset"] == "openai-speech"
    assert persisted["base_url"] == endpoint
    assert persisted["credential_id"] == credential.id
    assert :ok = Store.reload(:provider)
    assert {:ok, reloaded} = Providers.get(provider.id)
    assert reloaded.type == "openai_speech"
    assert reloaded.credential_id == credential.id
    assert reloaded.base_url == endpoint
    assert {:ok, runtime} = Providers.runtime_config(name)
    assert runtime.provider_id == provider.id
    assert runtime.provider_name == name
    assert runtime.type == "openai_speech"
    assert runtime.base_url == endpoint

    {:ok, index, _html} = live(conn, ~p"/settings/providers")
    assert has_element?(index, "a[href='/settings/providers/#{provider.id}']", name)
    assert render(index) =~ "Text to speech"
    assert render(index) =~ "Speech to text"
  end

  test "OpenAI Speech detail retains both capabilities while editing its connection", %{
    conn: conn
  } do
    credential = credential!()
    replacement = credential!()
    name = unique_name("openai-speech-detail")
    cleanup_provider(name)

    assert {:ok, provider} =
             Providers.create(%{
               name: name,
               type: "openai_speech",
               preset: "openai-speech",
               base_url: "https://api.openai.com",
               credential_id: credential.id,
               config: %{"model_catalog_migrated" => true}
             })

    {:ok, view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
    assert html =~ "Text to speech"
    assert html =~ "Speech to text"
    assert html =~ "tts.provider"
    assert html =~ "saved provider name"
    assert has_element?(view, "#speech-provider-reference", provider.name)
    assert has_element?(view, "input[name='base_url'][value='https://api.openai.com']")
    refute has_element?(view, "[phx-click='refresh_models']")
    refute has_element?(view, "[phx-click='toggle_chat']")
    refute html =~ "Manage Models"
    refute html =~ "stt.provider"

    endpoint = "https://openai-speech-edit.example.test/vendor/v1"

    html =
      react_form_submit(view, "edit-provider-form", %{
        "base_url" => endpoint,
        "credential_id" => replacement.id,
        "enabled" => true
      })

    assert html =~ "Provider updated"
    assert html =~ "Text to speech"
    assert html =~ "Speech to text"
    assert has_element?(view, "#speech-provider-reference", provider.name)
    assert {:ok, updated} = Providers.get(provider.id)
    assert updated.type == "openai_speech"
    assert updated.preset == "openai-speech"
    assert updated.base_url == endpoint
    assert updated.credential_id == replacement.id
    assert updated.enabled

    assert :ok = Store.reload(:provider)
    assert {:ok, runtime} = Providers.runtime_config(name)
    assert runtime.provider_id == provider.id
    assert runtime.type == "openai_speech"
    assert runtime.base_url == endpoint

    {:ok, reopened, html} = live(conn, ~p"/settings/providers/#{provider.id}")
    assert html =~ "Text to speech"
    assert html =~ "Speech to text"
    assert has_element?(reopened, "#speech-provider-reference", provider.name)
    assert has_element?(reopened, "input[name='base_url'][value='#{endpoint}']")

    assert has_element?(
             reopened,
             "select[name='credential_id'] option[value='#{replacement.id}'][selected]"
           )
  end

  test "OpenAI detail retains its Models and Test Chat panels", %{conn: conn} do
    name = unique_name("speech-ui-openai")
    cleanup_provider(name)

    assert {:ok, provider} =
             Providers.create(%{
               name: name,
               type: "openai",
               config: %{
                 "model_catalog_migrated" => true,
                 "available_models" => [%{"id" => "speech-ui-chat-fixture"}]
               }
             })

    {:ok, view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
    assert html =~ "Models"
    assert html =~ "Test Chat"
    assert has_element?(view, "[phx-click='refresh_models']", "Refresh Models")
    assert has_element?(view, "[phx-click='toggle_chat']", "Test Chat")
    assert has_element?(view, "a[href='/settings/models']", "Manage Models")
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
