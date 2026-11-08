defmodule SynapsisWeb.ProviderLive.FishAudioSpeechFunctionalTest do
  use SynapsisWeb.ConnCase
  import SynapsisWeb.ReactFormHelpers

  alias Synapsis.{Config.Store, Credentials, Models, Providers}

  test "explicit Fish Audio Speech preset creates a saved TTS-only provider with editable prefix",
       %{conn: conn} do
    credential = credential!()
    name = unique_name("my-fish-audio-voice")
    cleanup_provider(name)
    endpoint = "https://speech-ui.example.test/fish-audio/v7"

    {:ok, view, _html} = live(conn, ~p"/settings/providers/new")
    preset = ~s(button[phx-click="select_preset"][phx-value-name="fish-audio-speech"])
    assert has_element?(view, preset, "Fish Audio Speech")
    assert has_element?(view, preset, "Text to speech")
    view |> element(preset) |> render_click()

    assert has_element?(
             view,
             "input[name='base_url'][value='https://api.fish.audio']"
           )

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
    assert provider.type == "fish_audio_speech"
    assert provider.preset == "fish-audio-speech"
    assert provider.base_url == endpoint
    assert provider.credential_id == credential.id
    assert Providers.speech_only?(provider)
    assert Providers.speech_capabilities(provider) == [:tts]
    assert {:ok, []} = Models.list(provider_id: id)

    assert {:ok, toml} = Toml.decode(File.read!(Store.file_path(:provider)))
    assert persisted = Enum.find(toml["providers"], &(&1["id"] == id))
    assert persisted["name"] == name
    assert persisted["type"] == "fish_audio_speech"
    assert persisted["preset"] == "fish-audio-speech"
    assert persisted["base_url"] == endpoint
    assert persisted["credential_id"] == credential.id
    assert :ok = Store.reload(:provider)
    assert {:ok, reloaded} = Providers.get(id)
    assert reloaded.id == id
    assert reloaded.name == name
    assert reloaded.type == "fish_audio_speech"
    assert reloaded.preset == "fish-audio-speech"
    assert reloaded.credential_id == credential.id
    assert reloaded.base_url == endpoint
    assert {:ok, runtime} = Providers.runtime_config(name)
    assert runtime.provider_id == id
    assert runtime.provider_name == name
    assert runtime.type == "fish_audio_speech"
    assert runtime.base_url == endpoint

    {:ok, index, _html} = live(conn, ~p"/settings/providers")
    assert has_element?(index, "a[href='/settings/providers/#{id}']", name)
    assert render(index) =~ "Text to speech"
  end

  test "generic detail edit and reopen preserve Fish advanced settings and credential reference",
       %{conn: conn} do
    credential = credential!()
    replacement = credential!()
    name = unique_name("my-fish-audio-detail")
    cleanup_provider(name)

    config = %{
      "modelId" => "drama-3",
      "speakerVoiceId" => "saved-primary",
      "speaker_voice_id" => "saved-snake",
      "voiceId" => "saved-secondary",
      "voice_id" => "saved-snake-secondary",
      "referenceId" => "saved-third",
      "reference_id" => "saved-snake-third",
      "latency" => "low",
      "speed" => 1.2,
      "temperature" => 0.7,
      "topP" => 0.6,
      "normalize" => false,
      "timeout_ms" => 60_000,
      "max_bytes" => 8_192
    }

    assert {:ok, provider} =
             Providers.create(%{
               name: name,
               type: "fish_audio_speech",
               preset: "fish-audio-speech",
               base_url: "https://api.fish.audio",
               credential_id: credential.id,
               config: config
             })

    {:ok, view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
    assert html =~ "Text to speech"
    assert html =~ "tts.provider"
    assert html =~ "saved provider name"
    assert has_element?(view, "#speech-provider-reference", name)

    assert has_element?(
             view,
             "input[name='base_url'][value='https://api.fish.audio']"
           )

    refute has_element?(view, "[phx-click='refresh_models']")
    refute has_element?(view, "[phx-click='toggle_chat']")
    refute html =~ "Manage Models"
    endpoint = "https://speech-edit.example.test/fish-audio/v8"

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
    assert updated.type == "fish_audio_speech"
    assert updated.preset == "fish-audio-speech"
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
    assert reloaded.type == "fish_audio_speech"
    assert reloaded.preset == "fish-audio-speech"
    assert reloaded.credential_id == replacement.id
    assert reloaded.config == config
    assert {:ok, runtime} = Providers.runtime_config(name)
    assert runtime.provider_id == provider.id
    assert runtime.provider_name == name
    assert runtime.type == "fish_audio_speech"
    assert runtime.base_url == endpoint
    assert runtime_value(runtime, "modelId") == "drama-3"
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

  test "explicit asynchronous catalog refresh select save and reopen preserve advanced config", %{
    conn: conn
  } do
    credential = credential!()
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    name = unique_name("my-fish-catalog")
    cleanup_provider(name)

    config = %{
      "modelId" => "drama-3",
      "speakerVoiceId" => "old-primary",
      "speaker_voice_id" => "old-snake-primary",
      "voiceId" => "old-voice",
      "voice_id" => "old-snake-voice",
      "referenceId" => "old-reference",
      "reference_id" => "old-snake-reference",
      "latency" => "low",
      "speed" => 1.2,
      "temperature" => 0.7,
      "topP" => 0.6,
      "normalize" => false,
      "timeout_ms" => 60_000,
      "max_bytes" => 8_192
    }

    assert {:ok, provider} =
             Providers.create(%{
               name: name,
               type: "fish_audio_speech",
               preset: "fish-audio-speech",
               base_url: Gaoxy.Test.url(fixture, "/catalog"),
               credential_id: credential.id,
               config: config
             })

    owner = self()
    token = make_ref()
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)

    Gaoxy.Test.stub(fixture, "GET", "/catalog/model", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      index = Agent.get_and_update(counter, &{&1, &1 + 1})
      assert conn.query_params["type"] == "tts"
      assert conn.query_params["page_size"] == "100"
      assert conn.query_params["page_number"] == "1"

      items =
        if index == 0 do
          assert conn.query_params["self"] == "true"
          send(owner, {:fish_catalog_waiting, token, self()})

          receive do
            {:continue_fish_catalog, ^token} -> :ok
          after
            10_000 -> raise "LiveView did not remain responsive during ordinary voice refresh"
          end

          [
            %{
              "_id" => "owned-fish",
              "title" => " Owned Fish ",
              "visibility" => "private",
              "languages" => ["en-US"],
              "tags" => ["warm"]
            }
          ]
        else
          assert index == 1
          assert conn.query_params["sort_by"] == "score"

          [
            %{
              "_id" => "public-fish",
              "title" => " Public Fish ",
              "visibility" => "public",
              "languages" => ["ja-JP"],
              "tags" => ["gentle"]
            }
          ]
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"total" => length(items), "items" => items}))
    end)

    {:ok, view, _} = live(conn, ~p"/settings/providers/#{provider.id}")
    assert Agent.get(counter, & &1) == 0
    assert has_element?(view, "#fish-voice-form input[name='reference_id'][value='old-primary']")
    assert has_element?(view, "#fish-refresh-voices", "Refresh voices")
    view |> element("#fish-refresh-voices") |> render_click()
    assert_receive {:fish_catalog_waiting, ^token, server}, 5_000
    # This synchronous UI read completes while HTTP deliberately awaits the next
    # normal page. The catalog operation must run outside the LiveView process.
    assert has_element?(view, "#fish-voice-status")
    assert render(view) =~ ~r/loading|refreshing/i
    assert has_element?(view, "#speech-provider-reference", name)
    assert {:ok, ^provider} = Providers.get(provider.id)
    send(server, {:continue_fish_catalog, token})
    render_async(view, 10_000)
    assert has_element?(view, "#fish-voice-select option[value='owned-fish']", "Owned Fish")
    assert has_element?(view, "#fish-voice-select option[value='public-fish']", "Public Fish")
    assert render(view) =~ "ja-JP"
    assert render(view) =~ "private"
    assert {:ok, ^provider} = Providers.get(provider.id)
    view |> element("#fish-voice-select") |> render_change(%{"voice_id" => "public-fish"})
    assert has_element?(view, "#fish-voice-form input[name='reference_id'][value='public-fish']")
    assert {:ok, ^provider} = Providers.get(provider.id)
    assert has_element?(view, "#fish-save-voice", "Save voice")
    view |> form("#fish-voice-form", %{"reference_id" => "public-fish"}) |> render_submit()

    expected =
      config
      |> Map.drop(~w(speakerVoiceId speaker_voice_id voiceId voice_id referenceId))
      |> Map.put("reference_id", "public-fish")

    assert {:ok, saved} = Providers.get(provider.id)
    assert saved.config == expected
    assert saved.id == provider.id
    assert saved.name == provider.name
    assert saved.credential_id == credential.id
    assert saved.base_url == provider.base_url
    assert {:ok, []} = Models.list(provider_id: provider.id)
    assert {:ok, toml} = Toml.decode(File.read!(Store.file_path(:provider)))
    assert Enum.find(toml["providers"], &(&1["id"] == provider.id))["config"] == expected
    assert :ok = Store.reload(:provider)
    {:ok, reopened, _} = live(conn, ~p"/settings/providers/#{provider.id}")

    assert has_element?(
             reopened,
             "#fish-voice-form input[name='reference_id'][value='public-fish']"
           )

    assert Agent.get(counter, & &1) == 2
    # Free-form reference entry is independent of catalog discovery.
    reopened
    |> form("#fish-voice-form", %{"reference_id" => "manual-fish-reference"})
    |> render_submit()

    assert {:ok, manual} = Providers.get(provider.id)
    assert manual.config == Map.put(expected, "reference_id", "manual-fish-reference")
    assert Agent.get(counter, & &1) == 2
  end

  defp credential! do
    assert {:ok, credential} =
             Credentials.create(%{
               name: unique_name("fish-audio-ui-credential"),
               key: "ordinary-fish-audio-ui-fixture"
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
