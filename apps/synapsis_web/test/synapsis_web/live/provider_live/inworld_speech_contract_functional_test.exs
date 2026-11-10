defmodule SynapsisWeb.ProviderLive.InworldSpeechContractFunctionalTest do
  use SynapsisWeb.ConnCase, async: false
  @moduletag :functional

  alias Synapsis.{Config.Store, Credentials, Models, Providers}

  @models ~w(inworld-tts-1.5-max inworld-tts-1.5-mini inworld-tts-1-max inworld-tts-1)
  @form "#inworld-speech-form"
  @refresh "[phx-click='refresh_inworld_voices']"
  @voice "CustomInworldVoice"
  # Source-authored batch345 explicit-get-projection input. Literal order,
  # duplicates and optional fields are preserved; this is no codec fixture.
  @voices [
    %{
      "voiceId" => " Sarah ",
      "displayName" => " Sarah Voice ",
      "description" => " A calm narrator. ",
      "langCode" => " en-US ",
      "tags" => ["warm", "female", "male"],
      "source" => "curated"
    },
    %{
      "voiceId" => "Dennis",
      "displayName" => " Dennis ",
      "langCode" => "en-GB",
      "tags" => ["male", "female"]
    },
    %{
      "voiceId" => "Sarah",
      "displayName" => " Second Sarah ",
      "description" => "   ",
      "langCode" => "fr-CA",
      "tags" => ["neutral", "female"]
    },
    %{"voiceId" => "Minimal", "tags" => ["Male", "FEMALE", "character"]}
  ]

  test "ordinary defaults render four models and save explicit voice and temperature without HTTP",
       %{conn: conn} do
    {provider, fixture} = provider!(%{})
    trace_http()
    {:ok, view, _} = live(conn, ~p"/settings/providers/#{provider.id}")
    render_async(view, 10_000)
    assert_form(view)
    assert_selected(view, "inworld-tts-1.5-max", "Sarah")
    assert_temperature(view, nil)
    assert option_values(view, "#inworld-speech-models option") == @models
    assert has_element?(view, "#speech-provider-reference", provider.name)
    fields = selections("inworld-tts-1.5-mini", "Ashley", "0.75")
    view |> form(@form, fields) |> render_change()
    assert_selected(view, "inworld-tts-1.5-mini", "Ashley")
    assert_temperature(view, 0.75)
    assert {:ok, ^provider} = Providers.get(provider.id)
    view |> form(@form, fields) |> render_submit()
    expected = Map.merge(provider.config, selections("inworld-tts-1.5-mini", "Ashley", 0.75))
    assert_saved_reopened(conn, provider, expected, "inworld-tts-1.5-mini", "Ashley", 0.75)
    assert_empty_journal(fixture)
    assert_no_http()
  end

  test "every advertised model and literal custom model save and reopen with a custom voice",
       %{conn: conn} do
    {provider, fixture} = provider!(selections("inworld-tts-1.5-max", @voice, 0.8))
    trace_http()

    for model <- @models ++ ["__custom__"] do
      assert {:ok, current} = Providers.get(provider.id)
      {:ok, view, _} = live(conn, ~p"/settings/providers/#{provider.id}")
      assert option_values(view, "#inworld-speech-models option") == @models
      fields = selections(model, "ChosenCustomVoice", "1.25")
      view |> form(@form, fields) |> render_change()
      assert_selected(view, model, "ChosenCustomVoice")
      assert_temperature(view, 1.25)
      view |> form(@form, fields) |> render_submit()
      expected = Map.merge(current.config, selections(model, "ChosenCustomVoice", 1.25))
      assert_saved_reopened(conn, current, expected, model, "ChosenCustomVoice", 1.25)
      assert_empty_journal(fixture)
    end

    assert_no_http()
  end

  test "explicit asynchronous catalog refresh uses current UUID root and credential and retains draft",
       %{conn: conn} do
    {provider, fixture} = provider!(selections("tenant-saved-model", @voice, 0.8))
    replacement = credential!()
    owner = self()
    token = make_ref()

    Gaoxy.Test.expect_once(fixture, "GET", "/Current/Catalog/voices/v1/voices", fn conn ->
      assert conn.query_string == ""

      assert Plug.Conn.get_req_header(conn, "authorization") ==
               ["Basic current-inworld-ui-fixture"]

      assert {:ok, "", conn} = Plug.Conn.read_body(conn)
      send(owner, {:inworld_catalog_waiting, token, self()})

      receive do
        {:return_inworld_catalog, ^token} ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(%{"voices" => @voices}))
      after
        10_000 -> raise "ordinary Inworld catalog was not released"
      end
    end)

    trace_http()
    {:ok, view, _} = live(conn, ~p"/settings/providers/#{provider.id}")
    render_async(view, 10_000)
    assert_empty_journal(fixture)
    assert_no_http()
    draft = selections("tenant-draft-model", @voice, "1.1")
    view |> form(@form, draft) |> render_change()
    assert_selected(view, "tenant-draft-model", @voice)
    assert_temperature(view, 1.1)
    assert {:ok, _} = Credentials.update(replacement.id, %{key: "current-inworld-ui-fixture"})

    assert {:ok, current} =
             Providers.update(provider.id, %{
               base_url: Gaoxy.Test.url(fixture, "/Current/Catalog///"),
               credential_id: replacement.id
             })

    view |> element(@refresh) |> render_click()
    assert_receive {:inworld_catalog_waiting, ^token, response_owner}, 5_000
    # A live render remains responsive while this ordinary response is pending.
    assert_form(view)
    assert has_element?(view, @refresh <> "[disabled]")
    assert_selected(view, "tenant-draft-model", @voice)
    assert_temperature(view, 1.1)
    assert {:ok, ^current} = Providers.get(provider.id)
    send(response_owner, {:return_inworld_catalog, token})
    render_async(view, 10_000)

    assert option_values(view, "#inworld-speech-voices option") ==
             ["Sarah", "Dennis", "Sarah", "Minimal"]

    for label <- [
          "Sarah Voice",
          "A calm narrator.",
          "en-US",
          "female",
          "Dennis",
          "en-GB",
          "male",
          "Second Sarah",
          "fr-CA",
          "Minimal"
        ],
        do: assert(render(view) =~ label)

    assert_selected(view, "tenant-draft-model", @voice)
    assert_temperature(view, 1.1)
    assert {:ok, ^current} = Providers.get(provider.id)
    fields = selections("tenant-draft-model", "Dennis", "1.1")
    view |> form(@form, fields) |> render_submit()
    expected = Map.merge(current.config, selections("tenant-draft-model", "Dennis", 1.1))
    assert_saved_reopened(conn, current, expected, "tenant-draft-model", "Dennis", 1.1)

    assert %{entries: [entry], dropped: 0, cursor: 1, truncated: false} =
             Gaoxy.Test.requests(fixture)

    assert entry.method == "GET"
    assert entry.path == "/Current/Catalog/voices/v1/voices"
    assert entry.outcome == :ok
    assert entry.body == %{data: "", complete: true, truncated: false, limit: 8_192}
    assert_one_catalog_http()
  end

  test "stale full form patches only its edited model and preserves newer raw voice temperature and connection",
       %{conn: conn} do
    {provider, fixture} =
      provider!(%{
        "modelId" => " inworld-tts-1.5-mini ",
        "voiceId" => " SavedAliasVoice ",
        "temperature" => 1
      })

    replacement = credential!()
    trace_http()
    {:ok, view, _} = live(conn, ~p"/settings/providers/#{provider.id}")
    assert_selected(view, "inworld-tts-1.5-mini", "SavedAliasVoice")
    assert_temperature(view, 1)
    # Numeric 1.0 is semantically unchanged from mounted integer 1. The newer
    # raw 1.5 and voice alias must survive this later full form submission.
    fields = selections("inworld-tts-1-max", "SavedAliasVoice", "1.0")

    latest =
      Map.merge(provider.config, %{
        "modelId" => " inworld-tts-1 ",
        "voiceId" => " LatestRawVoice ",
        "temperature" => 1.5,
        "timeout_ms" => 81_000,
        "base_url" => "https://latest-saved-shadow.example.test/preserve-raw",
        "advanced_fixture" => %{"nested" => ["latest", %{"keep" => true}]},
        "current_unknown" => %{"retain" => [1, 2]}
      })

    assert {:ok, _} = Credentials.update(replacement.id, %{key: "current-inworld-ui-fixture"})

    assert {:ok, current} =
             Providers.update(provider.id, %{
               base_url: Gaoxy.Test.url(fixture, "/Latest/Connection///"),
               credential_id: replacement.id,
               config: latest
             })

    view |> form(@form, fields) |> render_change()
    assert {:ok, ^current} = Providers.get(provider.id)
    view |> form(@form, fields) |> render_submit()
    expected = latest |> Map.delete("modelId") |> Map.put("model_id", "inworld-tts-1-max")
    assert_saved_reopened(conn, current, expected, "inworld-tts-1-max", "LatestRawVoice", 1.5)
    assert_empty_journal(fixture)
    assert_no_http()
  end

  test "unchanged integer temperature stays integer when the browser submits equivalent numeric text",
       %{conn: conn} do
    {provider, fixture} =
      provider!(%{
        "modelId" => " inworld-tts-1-max ",
        "voiceId" => " RawAliasVoice ",
        "temperature" => 1
      })

    trace_http()
    {:ok, view, _} = live(conn, ~p"/settings/providers/#{provider.id}")
    fields = selections("inworld-tts-1-max", "RawAliasVoice", "1.0")
    view |> form(@form, fields) |> render_change()
    view |> form(@form, fields) |> render_submit()

    assert_saved_reopened(
      conn,
      provider,
      provider.config,
      "inworld-tts-1-max",
      "RawAliasVoice",
      1
    )

    assert {:ok, saved} = Providers.get(provider.id)
    assert is_integer(saved.config["temperature"])
    assert_empty_journal(fixture)
    assert_no_http()
  end

  test "edited camel selections become canonical and clearing optional temperature preserves unknown raw fields",
       %{conn: conn} do
    {provider, fixture} =
      provider!(%{
        "modelId" => "inworld-tts-1.5-mini",
        "voiceId" => "SavedAliasVoice",
        "temperature" => 0.8
      })

    trace_http()
    {:ok, view, _} = live(conn, ~p"/settings/providers/#{provider.id}")
    fields = selections("tenant-custom-model", "NewCustomVoice", "")
    view |> form(@form, fields) |> render_change()
    view |> form(@form, fields) |> render_submit()

    expected =
      provider.config
      |> Map.drop(~w(modelId voiceId temperature))
      |> Map.merge(%{"model_id" => "tenant-custom-model", "voice_id" => "NewCustomVoice"})

    assert_saved_reopened(conn, provider, expected, "tenant-custom-model", "NewCustomVoice", nil)
    assert_empty_journal(fixture)
    assert_no_http()
  end

  defp selections(model, voice, temperature),
    do: %{"model_id" => model, "voice_id" => voice, "temperature" => temperature}

  defp advanced_config do
    %{
      "timeoutMs" => 60_000,
      "timeout_ms" => 70_000,
      "max_bytes" => 65_536,
      "base_url" => "https://saved-shadow.example.test/preserve-raw",
      "advanced_fixture" => %{"nested" => ["one", %{"keep" => true}]}
    }
  end

  defp provider!(speech) do
    credential = credential!()
    fixture = Gaoxy.Test.open(capture_body: 8_192)
    on_exit(fn -> Gaoxy.Test.close(fixture) end)

    assert {:ok, provider} =
             Providers.create(%{
               name: "inworld-ui-" <> Ecto.UUID.generate(),
               type: "inworld_speech",
               preset: "inworld-speech",
               base_url: Gaoxy.Test.url(fixture, "/Custom/Route///"),
               credential_id: credential.id,
               config: Map.merge(advanced_config(), speech)
             })

    on_exit(fn -> Providers.delete(provider.id) end)
    {provider, fixture}
  end

  defp credential! do
    assert {:ok, credential} =
             Credentials.create(%{
               name: "inworld-ui-credential-" <> Ecto.UUID.generate(),
               key: "ordinary-inworld-ui-fixture"
             })

    on_exit(fn -> Credentials.delete(credential.id) end)
    credential
  end

  defp assert_form(view) do
    assert has_element?(
             view,
             "#inworld-speech-form[phx-change='change_inworld_speech'][phx-submit='save_inworld_speech']"
           )

    assert has_element?(
             view,
             "input#inworld-speech-model[name='model_id'][list='inworld-speech-models']"
           )

    assert has_element?(
             view,
             "input#inworld-speech-voice[name='voice_id'][list='inworld-speech-voices']"
           )

    assert has_element?(view, "input[name='temperature']")
    assert has_element?(view, @refresh, "Refresh voices")
  end

  defp assert_selected(view, model, voice) do
    assert has_element?(view, "#inworld-speech-model[value='#{model}']")
    assert has_element?(view, "#inworld-speech-voice[value='#{voice}']")
  end

  defp assert_temperature(view, nil),
    do: assert(has_element?(view, "[name='temperature'][value='']"))

  defp assert_temperature(view, expected) do
    assert [value] =
             view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#inworld-speech-form [name='temperature']")
             |> LazyHTML.attribute("value")

    assert {number, ""} = Float.parse(value)
    assert number == expected
  end

  defp assert_saved_reopened(conn, previous, expected, model, voice, temperature) do
    assert {:ok, saved} = Providers.get(previous.id)
    assert saved.config === expected

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
        do: assert(Map.fetch!(saved, key) === Map.fetch!(previous, key))

    assert {:ok, []} = Models.list(provider_id: previous.id)
    assert {:ok, toml} = Toml.decode(File.read!(Store.file_path(:provider)))
    assert Enum.find(toml["providers"], &(&1["id"] == previous.id))["config"] === expected
    assert :ok = Store.reload(:provider)
    assert {:ok, reloaded} = Providers.get(previous.id)
    assert reloaded.config === expected
    assert reloaded.base_url == previous.base_url
    assert reloaded.credential_id == previous.credential_id
    assert reloaded.api_key_encrypted == previous.api_key_encrypted
    {:ok, reopened, _} = live(conn, ~p"/settings/providers/#{previous.id}")
    render_async(reopened, 10_000)
    assert_form(reopened)
    assert_selected(reopened, model, voice)
    assert_temperature(reopened, temperature)
  end

  defp option_values(view, selector),
    do:
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.attribute("value")

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
    assert request.url.path == "/Current/Catalog/voices/v1/voices"
  end
end
