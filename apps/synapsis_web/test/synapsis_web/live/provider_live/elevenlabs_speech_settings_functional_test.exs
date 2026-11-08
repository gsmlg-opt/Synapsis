defmodule SynapsisWeb.ProviderLive.ElevenLabsSpeechSettingsFunctionalTest do
  use SynapsisWeb.ConnCase, async: false
  import SynapsisWeb.ReactFormHelpers

  alias Synapsis.{Config.Store, Credentials, Models, Providers}

  @models ~w(eleven_v3 eleven_multilingual_v2 eleven_flash_v2_5 eleven_flash_v2 eleven_turbo_v2_5 eleven_monolingual_v1)
  @form "#elevenlabs-speech-form"
  @refresh "[phx-click='refresh_elevenlabs_voices']"
  @voice "CustomVoice1234567"
  @voices [
    %{
      "voice_id" => " CatalogVoice12345 ",
      "name" => " Warm Narrator ",
      "category" => " professional ",
      "description" => " Clear and warm. "
    },
    %{
      "voice_id" => "OtherCatalog12345",
      "name" => "Calm Reader",
      "category" => "premade",
      "description" => "Measured delivery."
    }
  ]

  test "existing explicit preset keeps UUID identity and six model suggestions through save and reopen",
       %{conn: conn} do
    fixture = fixture!()
    credential = credential!()
    name = unique_name("elevenlabs-preset")
    cleanup_provider(name)
    trace_http()
    {:ok, view, _} = live(conn, ~p"/settings/providers/new")
    preset = ~s(button[phx-click="select_preset"][phx-value-name="elevenlabs"])
    assert has_element?(view, preset, "ElevenLabs")
    view |> element(preset) |> render_click()
    assert has_element?(view, "input[name='base_url'][value='https://api.elevenlabs.io']")
    root = Gaoxy.Test.url(fixture, "/Preset/Speech///")

    react_form_submit(view, "create-provider-form", %{
      "name" => name,
      "base_url" => root,
      "credential_id" => credential.id
    })

    assert %{"info" => "Provider created"} = assert_redirected(view, ~p"/settings/providers")
    assert {:ok, provider} = Providers.get_by_name(name)
    assert {:ok, _} = Ecto.UUID.cast(provider.id)
    assert provider.type == "elevenlabs"
    assert provider.preset == "elevenlabs"
    assert provider.base_url == root
    assert provider.credential_id == credential.id
    assert Providers.speech_capabilities(provider) == [:tts]
    assert {:ok, []} = Models.list(provider_id: provider.id)
    config = Map.merge(advanced_config(), selections("eleven_multilingual_v2", @voice))
    assert {:ok, provider} = Providers.update(provider.id, %{config: config})
    {:ok, detail, _} = live(conn, ~p"/settings/providers/#{provider.id}")
    assert_form(detail)
    assert has_element?(detail, "#speech-provider-reference", name)
    assert option_values(detail, "#elevenlabs-speech-models option") == @models
    assert_selected(detail, "eleven_multilingual_v2", @voice)
    refute has_element?(detail, "[phx-click='refresh_models']")
    refute has_element?(detail, "[phx-click='toggle_chat']")
    detail |> form(@form, selections("eleven_v3", "ChosenVoice1234567")) |> render_change()
    assert_selected(detail, "eleven_v3", "ChosenVoice1234567")
    assert {:ok, ^provider} = Providers.get(provider.id)
    detail |> form(@form, selections("eleven_v3", "ChosenVoice1234567")) |> render_submit()
    expected = Map.merge(config, selections("eleven_v3", "ChosenVoice1234567"))
    assert_saved_reopened(conn, provider, expected, "eleven_v3", "ChosenVoice1234567")
    assert_empty_journal(fixture)
    assert_no_http()
  end

  test "free model and voice inputs save explicit supported advanced edits and preserve unknown fields",
       %{conn: conn} do
    {provider, fixture} = provider!("tenant-original-model", @voice)
    trace_http()
    {:ok, view, _} = live(conn, ~p"/settings/providers/#{provider.id}")
    assert_form(view)
    assert_selected(view, "tenant-original-model", @voice)

    edited_settings =
      Map.merge(
        provider.config["voice_settings"],
        %{"stability" => 0.35, "style" => 0.4, "speed" => 1.3}
      )

    fields =
      Map.merge(selections("__custom__", "NewCustomVoice12345"), %{
        "seed" => "29",
        "apply_text_normalization" => "off",
        "language_code" => "ja",
        "voice_settings" => Jason.encode!(edited_settings)
      })

    view |> form(@form, fields) |> render_change()
    assert_selected(view, "__custom__", "NewCustomVoice12345")
    assert {:ok, ^provider} = Providers.get(provider.id)
    view |> form(@form, fields) |> render_submit()

    expected =
      Map.merge(
        provider.config,
        Map.merge(selections("__custom__", "NewCustomVoice12345"), %{
          "seed" => 29,
          "apply_text_normalization" => "off",
          "language_code" => "ja",
          "voice_settings" => edited_settings
        })
      )

    assert_saved_reopened(conn, provider, expected, "__custom__", "NewCustomVoice12345")
    assert_empty_journal(fixture)
    assert_no_http()
  end

  test "full form selection save rereads current UUID and preserves untouched newer raw advanced settings",
       %{conn: conn} do
    {provider, fixture} = provider!("eleven_multilingual_v2", @voice)
    replacement = credential!()
    trace_http()
    {:ok, view, _} = live(conn, ~p"/settings/providers/#{provider.id}")
    # Browser form submission includes every mounted field. Unedited advanced
    # controls must not overwrite a newer current UUID record with stale values.
    fields =
      Map.merge(full_form(provider.config), selections("eleven_flash_v2", "ChosenVoice1234567"))

    current_config =
      Map.merge(provider.config, %{
        "seed" => 91,
        "apply_text_normalization" => " ON ",
        "language_code" => " FR ",
        "voice_settings" => %{
          "stability" => 0.6,
          "similarity_boost" => 0.8,
          "style" => 0.2,
          "use_speaker_boost" => false,
          "speed" => 1.45,
          "current_unknown" => %{"preserve" => [1, 2]}
        },
        "voiceSettings" => %{"futureField" => "keep source alias raw"},
        "current_fixture" => ["keep", "all"]
      })

    assert {:ok, _} = Credentials.update(replacement.id, %{key: "current-elevenlabs-ui-fixture"})

    assert {:ok, current} =
             Providers.update(provider.id, %{
               base_url: Gaoxy.Test.url(fixture, "/Current/Connection///"),
               credential_id: replacement.id,
               config: current_config
             })

    view |> form(@form, fields) |> render_change()
    assert {:ok, ^current} = Providers.get(provider.id)
    view |> form(@form, fields) |> render_submit()
    expected = Map.merge(current_config, selections("eleven_flash_v2", "ChosenVoice1234567"))
    assert_saved_reopened(conn, current, expected, "eleven_flash_v2", "ChosenVoice1234567")
    assert {:ok, saved} = Providers.get(provider.id)
    assert saved.api_key_encrypted == "current-elevenlabs-ui-fixture"
    assert_empty_journal(fixture)
    assert_no_http()
  end

  test "explicit asynchronous voice refresh uses current root and credential, preserves draft and custom voice",
       %{conn: conn} do
    {provider, fixture} = provider!("tenant-current-model", @voice)
    replacement = credential!()
    owner = self()
    token = make_ref()

    Gaoxy.Test.expect_once(fixture, "GET", "/Current/Catalog/v1/voices", fn conn ->
      assert conn.query_string == ""
      assert Plug.Conn.get_req_header(conn, "xi-api-key") == ["current-elevenlabs-ui-fixture"]
      assert {:ok, "", conn} = Plug.Conn.read_body(conn)
      send(owner, {:elevenlabs_catalog_waiting, token, self()})

      receive do
        {:return_elevenlabs_catalog, ^token} ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(%{"voices" => @voices}))
      after
        10_000 -> raise "ordinary ElevenLabs catalog was not released"
      end
    end)

    trace_http()
    {:ok, view, _} = live(conn, ~p"/settings/providers/#{provider.id}")
    render_async(view, 10_000)
    assert_empty_journal(fixture)
    assert_no_http()

    draft =
      Map.merge(full_form(provider.config), %{"model_id" => "tenant-draft-model", "seed" => "37"})

    view |> form(@form, draft) |> render_change()
    assert_selected(view, "tenant-draft-model", @voice)
    assert {:ok, _} = Credentials.update(replacement.id, %{key: "current-elevenlabs-ui-fixture"})

    assert {:ok, current} =
             Providers.update(provider.id, %{
               base_url: Gaoxy.Test.url(fixture, "/Current/Catalog///"),
               credential_id: replacement.id
             })

    view |> element(@refresh) |> render_click()
    assert_receive {:elevenlabs_catalog_waiting, ^token, request}, 5_000
    # This live render must finish while the ordinary HTTP result is withheld.
    assert_form(view)
    assert_selected(view, "tenant-draft-model", @voice)
    assert has_element?(view, "[name='seed'][value='37']")
    assert {:ok, ^current} = Providers.get(provider.id)
    send(request, {:return_elevenlabs_catalog, token})
    render_async(view, 10_000)

    assert option_values(view, "#elevenlabs-speech-voices option") ==
             ["CatalogVoice12345", "OtherCatalog12345"]

    assert render(view) =~ "Warm Narrator"
    assert render(view) =~ "professional"
    assert render(view) =~ "Clear and warm."
    assert render(view) =~ "Calm Reader"
    assert render(view) =~ "premade"
    assert render(view) =~ "Measured delivery."
    assert_selected(view, "tenant-draft-model", @voice)
    assert has_element?(view, "[name='seed'][value='37']")
    assert {:ok, ^current} = Providers.get(provider.id)
    fields = Map.merge(draft, %{"voice_id" => "CatalogVoice12345"})
    view |> form(@form, fields) |> render_submit()

    expected =
      Map.merge(
        current.config,
        Map.merge(selections("tenant-draft-model", "CatalogVoice12345"), %{"seed" => 37})
      )

    assert_saved_reopened(conn, current, expected, "tenant-draft-model", "CatalogVoice12345")

    assert %{entries: [entry], dropped: 0, cursor: 1, truncated: false} =
             Gaoxy.Test.requests(fixture)

    assert entry.method == "GET"
    assert entry.path == "/Current/Catalog/v1/voices"
    assert entry.outcome == :ok
    assert entry.body == %{data: "", complete: true, truncated: false, limit: 8_192}

    assert Enum.filter(entry.headers, fn {key, _} -> key == "xi-api-key" end) ==
             [{"xi-api-key", "current-elevenlabs-ui-fixture"}]

    assert_one_catalog_http()
  end

  test "camel saved model and voice selections save canonical values without touching advanced source fields",
       %{conn: conn} do
    {provider, fixture} = provider!("eleven_multilingual_v2", @voice)

    config =
      provider.config
      |> Map.drop(~w(model_id voice_id))
      |> Map.merge(%{
        "modelId" => "eleven_turbo_v2_5",
        "voiceId" => "SavedAlias1234567",
        "voiceSettings" => %{
          "stability" => 0.45,
          "similarityBoost" => 0.85,
          "useSpeakerBoost" => false,
          "future_setting" => %{"keep" => true}
        }
      })

    assert {:ok, provider} = Providers.update(provider.id, %{config: config})
    trace_http()
    {:ok, view, _} = live(conn, ~p"/settings/providers/#{provider.id}")
    assert_selected(view, "eleven_turbo_v2_5", "SavedAlias1234567")
    view |> form(@form, selections("eleven_v3", "ChosenAlias1234567")) |> render_submit()

    expected =
      config
      |> Map.drop(~w(modelId voiceId))
      |> Map.merge(selections("eleven_v3", "ChosenAlias1234567"))

    assert_saved_reopened(conn, provider, expected, "eleven_v3", "ChosenAlias1234567")
    assert_empty_journal(fixture)
    assert_no_http()
  end

  test "every advertised model and ordinary literal custom model save and reopen without HTTP",
       %{conn: conn} do
    {provider, fixture} = provider!("eleven_multilingual_v2", @voice)
    trace_http()

    for model <- @models ++ ["__custom__"] do
      assert {:ok, current} = Providers.get(provider.id)
      {:ok, view, _} = live(conn, ~p"/settings/providers/#{provider.id}")
      assert option_values(view, "#elevenlabs-speech-models option") == @models

      view
      |> form(@form, Map.merge(full_form(current.config), selections(model, @voice)))
      |> render_submit()

      expected = Map.merge(current.config, selections(model, @voice))
      assert_saved_reopened(conn, current, expected, model, @voice)
      assert_empty_journal(fixture)
    end

    assert_no_http()
  end

  defp advanced_config do
    %{
      "seed" => 17,
      "apply_text_normalization" => "auto",
      "language_code" => "en",
      "voice_settings" => %{
        "stability" => 0.2,
        "similarity_boost" => 0.9,
        "style" => 0.3,
        "use_speaker_boost" => true,
        "speed" => 1.1,
        "future_setting" => %{"keep" => ["original"]}
      },
      "timeoutMs" => 60_000,
      "timeout_ms" => 70_000,
      "max_bytes" => 65_536,
      "outputFormat" => "opus_48000_64",
      "latencyTier" => 2,
      "advanced_fixture" => %{"labels" => ["one", "two"]}
    }
  end

  defp full_form(config) do
    %{
      "model_id" => config["model_id"],
      "voice_id" => config["voice_id"],
      "seed" => to_string(config["seed"]),
      "apply_text_normalization" => config["apply_text_normalization"],
      "language_code" => config["language_code"],
      "voice_settings" => Jason.encode!(config["voice_settings"])
    }
  end

  defp selections(model, voice), do: %{"model_id" => model, "voice_id" => voice}

  defp provider!(model, voice) do
    credential = credential!()
    fixture = fixture!()
    name = unique_name("elevenlabs-custom")
    cleanup_provider(name)

    assert {:ok, provider} =
             Providers.create(%{
               name: name,
               type: "elevenlabs",
               preset: "elevenlabs",
               base_url: Gaoxy.Test.url(fixture, "/Custom/Route///"),
               credential_id: credential.id,
               config: Map.merge(advanced_config(), selections(model, voice))
             })

    {provider, fixture}
  end

  defp fixture! do
    fixture = Gaoxy.Test.open(capture_body: 8_192)
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    fixture
  end

  defp assert_form(view) do
    assert has_element?(
             view,
             "#elevenlabs-speech-form[phx-change='change_elevenlabs_speech'][phx-submit='save_elevenlabs_speech']"
           )

    assert has_element?(
             view,
             "input#elevenlabs-speech-model[name='model_id'][list='elevenlabs-speech-models']"
           )

    assert has_element?(
             view,
             "input#elevenlabs-speech-voice[name='voice_id'][list='elevenlabs-speech-voices']"
           )

    assert has_element?(view, "[name='seed']")
    assert has_element?(view, "[name='apply_text_normalization']")
    assert has_element?(view, "[name='language_code']")
    assert has_element?(view, "textarea[name='voice_settings']")
    assert has_element?(view, @refresh, "Refresh voices")
  end

  defp assert_selected(view, model, voice) do
    assert has_element?(view, "#elevenlabs-speech-model[value='#{model}']")
    assert has_element?(view, "#elevenlabs-speech-voice[value='#{voice}']")
  end

  defp assert_saved_reopened(conn, previous, expected, model, voice) do
    assert {:ok, saved} = Providers.get(previous.id)
    assert saved.config == expected

    for key <- [
          :id,
          :name,
          :type,
          :preset,
          :base_url,
          :credential_id,
          :api_key_encrypted,
          :enabled
        ],
        do: assert(Map.fetch!(saved, key) == Map.fetch!(previous, key))

    assert {:ok, []} = Models.list(provider_id: previous.id)
    assert {:ok, toml} = Toml.decode(File.read!(Store.file_path(:provider)))
    assert Enum.find(toml["providers"], &(&1["id"] == previous.id))["config"] == expected
    assert :ok = Store.reload(:provider)
    assert {:ok, reloaded} = Providers.get(previous.id)
    assert reloaded.config == expected
    assert reloaded.base_url == previous.base_url
    assert reloaded.credential_id == previous.credential_id
    assert reloaded.api_key_encrypted == previous.api_key_encrypted
    {:ok, reopened, _} = live(conn, ~p"/settings/providers/#{previous.id}")
    render_async(reopened, 10_000)
    assert_form(reopened)
    assert_selected(reopened, model, voice)

    assert has_element?(
             reopened,
             "select[name='credential_id'] option[value='#{previous.credential_id}'][selected]"
           )

    assert {:ok, []} = Models.list(provider_id: previous.id)
  end

  defp option_values(view, selector),
    do:
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.attribute("value")

  defp credential! do
    assert {:ok, credential} =
             Credentials.create(%{
               name: unique_name("elevenlabs-ui-credential"),
               key: "ordinary-elevenlabs-ui-fixture"
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

  defp assert_empty_journal(fixture),
    do:
      assert(
        Gaoxy.Test.requests(fixture) == %{entries: [], dropped: 0, cursor: 0, truncated: false}
      )

  defp trace_http do
    Code.ensure_loaded!(Req)
    :erlang.trace_pattern({Req, :request, 1}, true, [:local])
    :erlang.trace(:all, true, [:call, {:tracer, self()}])

    on_exit(fn ->
      :erlang.trace(:all, false, [:call])
      :erlang.trace_pattern({Req, :request, 1}, false, [:local])
    end)
  end

  defp http_calls do
    barrier = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^barrier}, 5_000
    drain_http([])
  end

  defp drain_http(calls) do
    receive do
      {:trace, pid, :call, {Req, :request, arguments}} -> drain_http([{pid, arguments} | calls])
    after
      0 -> Enum.reverse(calls)
    end
  end

  defp assert_no_http, do: assert(http_calls() == [])

  defp assert_one_catalog_http do
    assert [{_task, [%Req.Request{} = request]}] = http_calls()
    assert request.method == :get
    assert request.url.path == "/Current/Catalog/v1/voices"
  end
end
