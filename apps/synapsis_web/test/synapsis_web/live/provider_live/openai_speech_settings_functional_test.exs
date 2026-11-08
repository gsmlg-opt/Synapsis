defmodule SynapsisWeb.ProviderLive.OpenAISpeechSettingsFunctionalTest do
  use SynapsisWeb.ConnCase
  import SynapsisWeb.ReactFormHelpers

  alias Synapsis.{Config.Store, Credentials, Models, Providers}

  @models ~w(gpt-4o-mini-tts gpt-4o-mini-tts-2025-12-15 tts-1 tts-1-hd)
  @voices ~w(alloy ash ballad cedar coral echo fable juniper marin onyx nova sage shimmer verse)
  @form "#openai-speech-form"

  test "existing explicit preset uses API root and official static selections save and reopen", %{
    conn: conn
  } do
    credential = credential!()
    name = "openai-official-#{Ecto.UUID.generate()}"
    cleanup_provider(name)
    trace_http()
    {:ok, view, _} = live(conn, ~p"/settings/providers/new")
    preset = ~s(button[phx-click="select_preset"][phx-value-name="openai-speech"])
    assert has_element?(view, preset, "OpenAI")
    view |> element(preset) |> render_click()
    assert has_element?(view, "input[name='base_url'][value='https://api.openai.com']")

    react_form_submit(view, "create-provider-form", %{
      "name" => name,
      "base_url" => "https://api.openai.com",
      "credential_id" => credential.id
    })

    assert %{"info" => "Provider created"} = assert_redirected(view, ~p"/settings/providers")
    assert {:ok, provider} = Providers.get_by_name(name)
    assert {:ok, _} = Ecto.UUID.cast(provider.id)
    assert provider.type == "openai_speech"
    assert provider.preset == "openai-speech"
    assert provider.base_url == "https://api.openai.com"
    assert Providers.speech_capabilities(provider) == [:tts, :stt]
    assert {:ok, []} = Models.list(provider_id: provider.id)
    assert provider.config == %{"model_catalog_migrated" => true}

    config =
      advanced_config() |> Map.merge(%{"model" => " gpt-4o-mini-tts ", "voice" => " coral "})

    assert {:ok, provider} = Providers.update(provider.id, %{config: config})
    {:ok, detail, _} = live(conn, ~p"/settings/providers/#{provider.id}")
    assert_form(detail)
    assert has_element?(detail, "#speech-provider-reference", name)
    assert option_values(detail, "#openai-speech-model option") == @models
    assert option_values(detail, "#openai-speech-voice option") == @voices
    assert_selected(detail, "gpt-4o-mini-tts", "coral")
    refute has_element?(detail, "[phx-click='refresh_models']")
    refute has_element?(detail, "[phx-click='toggle_chat']")
    detail |> form(@form, %{"model" => "tts-1-hd", "voice" => "verse"}) |> render_change()
    assert_selected(detail, "tts-1-hd", "verse")
    assert {:ok, ^provider} = Providers.get(provider.id)
    detail |> form(@form, %{"model" => "tts-1-hd", "voice" => "verse"}) |> render_submit()
    expected = Map.merge(config, %{"model" => "tts-1-hd", "voice" => "verse"})
    assert_saved_reopened(conn, provider, expected, "tts-1-hd", "verse")
    assert_no_http()
  end

  test "current custom route model and voice remain selected extra choices through mount and explicit save",
       %{conn: conn} do
    {provider, fixture} =
      custom_provider!(%{
        "model" => " tenant-original-model ",
        "voice" => " Tenant Original Voice "
      })

    trace_http()
    {:ok, view, _} = live(conn, ~p"/settings/providers/#{provider.id}")
    assert_form(view)
    assert_selected(view, "tenant-original-model", "Tenant Original Voice")
    assert has_element?(view, "#openai-speech-model option[value='__custom__']")
    assert has_element?(view, "#openai-speech-voice option[value='__custom__']")

    assert Enum.reject(
             option_values(view, "#openai-speech-model option"),
             &(&1 in ["tenant-original-model", "__custom__"])
           ) == @models

    assert Enum.reject(
             option_values(view, "#openai-speech-voice option"),
             &(&1 in ["Tenant Original Voice", "__custom__"])
           ) == @voices

    assert {:ok, ^provider} = Providers.get(provider.id)

    view
    |> form(@form, %{"model" => "tenant-original-model", "voice" => "Tenant Original Voice"})
    |> render_submit()

    expected =
      Map.merge(provider.config, %{
        "model" => "tenant-original-model",
        "voice" => "Tenant Original Voice"
      })

    assert_saved_reopened(
      conn,
      provider,
      expected,
      "tenant-original-model",
      "Tenant Original Voice"
    )

    assert Gaoxy.Test.requests(fixture) == %{entries: [], dropped: 0, cursor: 0, truncated: false}
    assert_no_http()
  end

  test "custom route accepts explicit new custom selections and retains advanced settings on reopen",
       %{conn: conn} do
    {provider, fixture} = custom_provider!(%{"model" => "gpt-4o-mini-tts", "voice" => "coral"})
    trace_http()
    {:ok, view, _} = live(conn, ~p"/settings/providers/#{provider.id}")
    view |> form(@form, %{"model" => "__custom__", "voice" => "__custom__"}) |> render_change()
    assert has_element?(view, "input#openai-speech-custom-model[name='custom_model']")
    assert has_element?(view, "input#openai-speech-custom-voice[name='custom_voice']")
    assert {:ok, ^provider} = Providers.get(provider.id)

    view
    |> form(@form, %{
      "model" => "__custom__",
      "voice" => "__custom__",
      "custom_model" => " tenant-new-model ",
      "custom_voice" => " Tenant New Voice "
    })
    |> render_submit()

    expected =
      Map.merge(provider.config, %{"model" => "tenant-new-model", "voice" => "Tenant New Voice"})

    assert_saved_reopened(conn, provider, expected, "tenant-new-model", "Tenant New Voice")
    assert Gaoxy.Test.requests(fixture) == %{entries: [], dropped: 0, cursor: 0, truncated: false}
    assert_no_http()
  end

  test "explicit selection save rereads current UUID and preserves newer advanced connection and credential values",
       %{conn: conn} do
    {provider, fixture} = custom_provider!(%{"model" => "tts-1", "voice" => "echo"})
    replacement = credential!()
    trace_http()
    {:ok, view, _} = live(conn, ~p"/settings/providers/#{provider.id}")

    view
    |> form(@form, %{"model" => "gpt-4o-mini-tts-2025-12-15", "voice" => "marin"})
    |> render_change()

    assert {:ok, ^provider} = Providers.get(provider.id)

    current_config =
      provider.config
      |> Map.merge(%{
        "speed" => 1.45,
        "instructions" => "Current advanced direction.",
        "responseFormat" => "opus",
        "extraBody" => %{"language" => "ja", "metadata" => %{"current" => true}},
        "timeoutMs" => 90_000,
        "current_fixture" => ["keep", "all"]
      })

    assert {:ok, _} = Credentials.update(replacement.id, %{key: "current-openai-ui-fixture"})

    assert {:ok, current} =
             Providers.update(provider.id, %{
               base_url: Gaoxy.Test.url(fixture, "/Current/Route/v1///"),
               credential_id: replacement.id,
               config: current_config
             })

    view
    |> form(@form, %{"model" => "gpt-4o-mini-tts-2025-12-15", "voice" => "marin"})
    |> render_submit()

    expected =
      Map.merge(current_config, %{"model" => "gpt-4o-mini-tts-2025-12-15", "voice" => "marin"})

    assert_saved_reopened(conn, current, expected, "gpt-4o-mini-tts-2025-12-15", "marin")
    assert {:ok, saved} = Providers.get(provider.id)
    assert saved.api_key_encrypted == "current-openai-ui-fixture"
    assert Gaoxy.Test.requests(fixture) == %{entries: [], dropped: 0, cursor: 0, truncated: false}
    assert_no_http()
  end

  test "ECMAScript-trimmed official root uses official menus and preserves the saved raw route",
       %{
         conn: conn
       } do
    credential = credential!()
    name = "openai-official-ecma-#{Ecto.UUID.generate()}"
    cleanup_provider(name)
    root = "\uFEFF https://api.openai.com/v1/// \uFEFF"
    config = Map.merge(advanced_config(), %{"model" => "tts-1", "voice" => "alloy"})

    assert {:ok, provider} =
             Providers.create(%{
               name: name,
               type: "openai_speech",
               preset: "openai-speech",
               base_url: "https://api.openai.com",
               credential_id: credential.id,
               config: config
             })

    # Existing TOML roots are read through the owning Config.Store API;
    # creating a new provider separately validates the entered URL.
    assert {:ok, stored} = Store.get(:provider, provider.id)

    assert {:ok, _} =
             Store.replace_existing(:provider, provider.id, Map.put(stored, "base_url", root))

    assert :ok = Store.reload(:provider)
    assert {:ok, provider} = Providers.get(provider.id)
    assert provider.base_url == root
    trace_http()
    {:ok, view, _} = live(conn, ~p"/settings/providers/#{provider.id}")
    assert_form(view)
    assert option_values(view, "#openai-speech-model option") == @models
    assert option_values(view, "#openai-speech-voice option") == @voices
    assert_selected(view, "tts-1", "alloy")
    view |> form(@form, %{"model" => "tts-1-hd", "voice" => "verse"}) |> render_submit()
    expected = Map.merge(config, %{"model" => "tts-1-hd", "voice" => "verse"})
    assert_saved_reopened(conn, provider, expected, "tts-1-hd", "verse")
    assert_no_http()
  end

  test "literal custom sentinel names remain selected through save and custom entry reopen", %{
    conn: conn
  } do
    {provider, fixture} = custom_provider!(%{"model" => "__custom__", "voice" => "__custom__"})
    trace_http()
    {:ok, view, _} = live(conn, ~p"/settings/providers/#{provider.id}")
    assert_selected(view, "__custom__", "__custom__")

    assert option_values(view, "#openai-speech-model option") ==
             @models ++ ["__custom__", "__custom___"]

    assert option_values(view, "#openai-speech-voice option") ==
             @voices ++ ["__custom__", "__custom___"]

    assert has_element?(view, "#openai-speech-model option[value='__custom__']", "__custom__")
    assert has_element?(view, "#openai-speech-voice option[value='__custom__']", "__custom__")
    assert has_element?(view, "#openai-speech-model option[value='__custom___']", "Custom value…")
    assert has_element?(view, "#openai-speech-voice option[value='__custom___']", "Custom value…")
    refute has_element?(view, "#openai-speech-custom-model")
    refute has_element?(view, "#openai-speech-custom-voice")
    assert {:ok, ^provider} = Providers.get(provider.id)
    view |> form(@form, %{"model" => "__custom__", "voice" => "__custom__"}) |> render_submit()
    assert_saved_reopened(conn, provider, provider.config, "__custom__", "__custom__")
    assert {:ok, provider} = Providers.get(provider.id)

    {:ok, current, _} = live(conn, ~p"/settings/providers/#{provider.id}")

    current
    |> form(@form, %{"model" => "__custom___", "voice" => "__custom___"})
    |> render_change()

    assert has_element?(current, "#openai-speech-custom-model")
    assert has_element?(current, "#openai-speech-custom-voice")
    assert {:ok, ^provider} = Providers.get(provider.id)

    current
    |> form(@form, %{
      "model" => "__custom___",
      "voice" => "__custom___",
      "custom_model" => "__custom___",
      "custom_voice" => "__custom___"
    })
    |> render_submit()

    expected = Map.merge(provider.config, %{"model" => "__custom___", "voice" => "__custom___"})
    assert_saved_reopened(conn, provider, expected, "__custom___", "__custom___")
    {:ok, reopened, _} = live(conn, ~p"/settings/providers/#{provider.id}")

    assert has_element?(
             reopened,
             "#openai-speech-model option[value='__custom___']",
             "__custom___"
           )

    assert has_element?(
             reopened,
             "#openai-speech-voice option[value='__custom___']",
             "__custom___"
           )

    assert has_element?(
             reopened,
             "#openai-speech-model option[value='__custom__']",
             "Custom value…"
           )

    assert has_element?(
             reopened,
             "#openai-speech-voice option[value='__custom__']",
             "Custom value…"
           )

    refute has_element?(reopened, "#openai-speech-custom-model")
    refute has_element?(reopened, "#openai-speech-custom-voice")
    assert Gaoxy.Test.requests(fixture) == %{entries: [], dropped: 0, cursor: 0, truncated: false}
    assert_no_http()
  end

  defp advanced_config do
    %{
      "responseFormat" => " WAV ",
      "response_format" => "mp3",
      "speed" => 1.25,
      "instructions" => " Keep the complete advanced instruction. ",
      "extraBody" => %{"language" => "en", "metadata" => %{"preserve" => true}},
      "extra_body" => %{"seed" => 17},
      "timeoutMs" => 60_000,
      "timeout_ms" => 70_000,
      "max_bytes" => 65_536,
      "modelId" => "unrelated-talk-model",
      "voiceId" => "unrelated-talk-voice",
      "advanced_fixture" => %{"labels" => ["one", "two"]}
    }
  end

  defp custom_provider!(selections) do
    credential = credential!()
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    name = "openai-custom-#{Ecto.UUID.generate()}"
    cleanup_provider(name)

    assert {:ok, provider} =
             Providers.create(%{
               name: name,
               type: "openai_speech",
               preset: "openai-speech",
               base_url: Gaoxy.Test.url(fixture, "/Custom/Route"),
               credential_id: credential.id,
               config: Map.merge(advanced_config(), selections)
             })

    {provider, fixture}
  end

  defp assert_form(view) do
    assert has_element?(
             view,
             "#openai-speech-form[phx-change='openai_speech_selection_change'][phx-submit='openai_speech_selection_save']"
           )

    assert has_element?(view, "select#openai-speech-model[name='model']")
    assert has_element?(view, "select#openai-speech-voice[name='voice']")
    assert has_element?(view, "#openai-save-speech", "Save speech settings")
  end

  defp assert_selected(view, model, voice) do
    assert has_element?(view, "#openai-speech-model option[value='#{model}'][selected]")
    assert has_element?(view, "#openai-speech-voice option[value='#{voice}'][selected]")
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
               name: "openai-ui-credential-#{Ecto.UUID.generate()}",
               key: "ordinary-openai-ui-fixture"
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

  defp trace_http do
    Code.ensure_loaded!(Req)
    :erlang.trace_pattern({Req, :request, 1}, true, [:local])
    :erlang.trace(:all, true, [:call, {:tracer, self()}])

    on_exit(fn ->
      :erlang.trace(:all, false, [:call])
      :erlang.trace_pattern({Req, :request, 1}, false, [:local])
    end)
  end

  defp assert_no_http do
    barrier = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^barrier}, 5_000
    refute_receive {:trace, _, :call, {Req, :request, _}}, 50
  end
end
