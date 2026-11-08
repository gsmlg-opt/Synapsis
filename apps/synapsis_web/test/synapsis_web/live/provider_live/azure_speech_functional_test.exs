defmodule SynapsisWeb.ProviderLive.AzureSpeechFunctionalTest do
  use SynapsisWeb.ConnCase, async: false

  import SynapsisWeb.ReactFormHelpers

  alias Synapsis.Agent.{MediaDelivery, Tools.ResultProjection}
  alias Synapsis.Config.Store
  alias Synapsis.Workspace.Media
  alias Synapsis.{Credentials, Models, Providers}

  @moduletag :tmp_dir
  @audio <<0, 1, 2, 254, 255>>
  @voices [
    %{
      "ShortName" => " fr-FR-DeniseNeural ",
      "DisplayName" => " Denise ",
      "Locale" => " fr-FR ",
      "Gender" => " Female ",
      "Status" => "Active",
      "VoiceTag" => %{
        "TailoredScenarios" => [" General ", " Assistant "],
        "VoicePersonalities" => [" Warm ", " Friendly "]
      }
    },
    %{
      "ShortName" => "en-US-JennyNeural",
      "LocalName" => " Jenny local ",
      "Locale" => "en-US",
      "Gender" => "Female",
      "VoiceTag" => %{"VoicePersonalities" => [" Cheerful "]}
    },
    %{
      "ShortName" => "en-US-JennyNeural",
      "DisplayName" => "Jenny duplicate",
      "Status" => "Preview",
      "VoiceTag" => %{"TailoredScenarios" => [" narration "]}
    },
    %{"ShortName" => "de-DE-KatjaNeural", "DisplayName" => "Katja"}
  ]

  test "explicit editable Azure preset creates speech-only UUID identity and reopens TOML settings",
       %{conn: conn} do
    credential = credential!("preset")
    name = "my-azure-speech-#{Ecto.UUID.generate()}"
    cleanup_provider(name)
    endpoint = "https://speech-ui.example.test/tenant/cognitiveservices/v1"
    {:ok, view, _} = live(conn, ~p"/settings/providers/new")
    preset = ~s(button[phx-click="select_preset"][phx-value-name="azure-speech"])
    assert has_element?(view, preset, "Azure Speech")
    assert has_element?(view, preset, "Text to speech")
    view |> element(preset) |> render_click()
    assert has_element?(view, "input[name='base_url'][value='']")

    react_form_submit(view, "create-provider-form", %{
      "name" => name,
      "base_url" => endpoint,
      "credential_id" => credential.id
    })

    assert %{"info" => "Provider created"} = assert_redirected(view, ~p"/settings/providers")
    assert {:ok, provider} = Providers.get_by_name(name)
    id = provider.id
    assert {:ok, ^id} = Ecto.UUID.cast(id)
    assert provider.type == "azure_speech"
    assert provider.preset == "azure-speech"
    assert provider.base_url == endpoint
    assert provider.credential_id == credential.id
    assert Providers.speech_capabilities(provider) == [:tts]
    assert {:ok, []} = Models.list(provider_id: id)

    config = advanced_config()
    assert {:ok, _} = Providers.update(id, %{config: config})
    assert :ok = Store.reload(:provider)
    assert {:ok, reloaded} = Providers.get(id)
    assert reloaded.config == config
    {:ok, reopened, html} = live(conn, ~p"/settings/providers/#{id}")
    assert html =~ "Text to speech"
    assert html =~ "tts.provider"
    assert has_element?(reopened, "#speech-provider-reference", name)
    assert has_element?(reopened, "#azure-speech-voice[value='Custom Current Voice']")
    refute has_element?(reopened, "[phx-click='refresh_models']")
    refute has_element?(reopened, "[phx-click='toggle_chat']")
  end

  test "explicit async refresh uses current UUID credential and ordered catalog; voice selection saves narrowly",
       %{conn: conn} do
    credential = credential!("initial")
    replacement = credential!("replacement")
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    counter = start_supervised!({Agent, fn -> %{voices: 0, synthesis: 0} end})
    owner = self()

    Gaoxy.Test.stub(fixture, "GET", "/tenant/cognitiveservices/voices/list", fn conn ->
      assert Plug.Conn.get_req_header(conn, "ocp-apim-subscription-key") ==
               ["current-azure-ui-fixture"]

      assert conn.query_string == ""
      assert {:ok, "", conn} = Plug.Conn.read_body(conn)
      Agent.update(counter, &Map.update!(&1, :voices, fn n -> n + 1 end))
      send(owner, {:azure_voice_request, self()})

      receive do
        :return_ordinary_catalog ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(@voices))
      after
        10_000 -> raise "ordinary voice catalog fixture was not released"
      end
    end)

    Gaoxy.Test.stub(fixture, "POST", "/tenant/cognitiveservices/v1", fn conn ->
      Agent.update(counter, &Map.update!(&1, :synthesis, fn n -> n + 1 end))
      Plug.Conn.resp(conn, 200, @audio)
    end)

    name = "custom-azure-selection-#{Ecto.UUID.generate()}"
    cleanup_provider(name)
    config = advanced_config()

    assert {:ok, provider} =
             Providers.create(%{
               name: name,
               type: "azure_speech",
               preset: "azure-speech",
               base_url: Gaoxy.Test.url(fixture, "/tenant/CognitiveServices/V1///"),
               credential_id: credential.id,
               config: config
             })

    {:ok, view, _} = live(conn, ~p"/settings/providers/#{provider.id}")
    render_async(view, 10_000)
    assert Agent.get(counter, & &1) == %{voices: 0, synthesis: 0}
    assert has_element?(view, "#azure-refresh-voices", "Refresh voices")
    assert has_element?(view, "#azure-save-voice", "Save voice")

    assert has_element?(
             view,
             "#azure-speech-form[phx-change='azure_selection_change'][phx-submit='azure_selection_save']"
           )

    assert has_element?(
             view,
             "#azure-speech-voice[name='voice'][list='azure-speech-voices'][value='Custom Current Voice']"
           )

    # The mounted socket retains the selected UUID, while refresh rereads that record.
    assert {:ok, _} = Providers.update(provider.id, %{credential_id: replacement.id})
    assert {:ok, _} = Credentials.update(replacement.id, %{key: "current-azure-ui-fixture"})
    assert {:ok, current} = Providers.get(provider.id)
    view |> element("#azure-refresh-voices") |> render_click()
    assert_receive {:azure_voice_request, request}, 5_000
    assert has_element?(view, "#azure-refresh-voices[disabled]")
    assert render(view) =~ "Refreshing voices"
    send(request, :return_ordinary_catalog)
    render_async(view, 10_000)

    option_ids =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#azure-speech-voices option")
      |> LazyHTML.attribute("value")

    assert option_ids == [
             "fr-FR-DeniseNeural",
             "en-US-JennyNeural",
             "en-US-JennyNeural",
             "de-DE-KatjaNeural"
           ]

    assert has_element?(view, "#azure-speech-voice[value='Custom Current Voice']")
    assert {:ok, ^current} = Providers.get(provider.id)
    assert Agent.get(counter, & &1) == %{voices: 1, synthesis: 0}

    view
    |> form("#azure-speech-form", %{"voice" => "fr-FR-DeniseNeural"})
    |> render_change()

    assert has_element?(view, "#azure-speech-voice[value='fr-FR-DeniseNeural']")
    assert {:ok, ^current} = Providers.get(provider.id)

    view
    |> form("#azure-speech-form", %{"voice" => "fr-FR-DeniseNeural"})
    |> render_submit()

    assert render(view) =~ "Voice saved"

    expected =
      config |> Map.drop(~w(voice voiceId voice_id)) |> Map.put("voice", "fr-FR-DeniseNeural")

    assert {:ok, saved} = Providers.get(provider.id)
    assert saved.config == expected
    assert saved.id == current.id
    assert saved.name == name
    assert saved.base_url == current.base_url
    assert saved.credential_id == replacement.id
    assert {:ok, []} = Models.list(provider_id: saved.id)
    assert {:ok, toml} = Toml.decode(File.read!(Store.file_path(:provider)))
    assert Enum.find(toml["providers"], &(&1["id"] == saved.id))["config"] == expected
    assert :ok = Store.reload(:provider)
    {:ok, reopened, _} = live(conn, ~p"/settings/providers/#{saved.id}")
    render_async(reopened, 10_000)
    assert has_element?(reopened, "#azure-speech-voice[value='fr-FR-DeniseNeural']")
    assert Agent.get(counter, & &1) == %{voices: 1, synthesis: 0}

    reopened
    |> form("#azure-speech-form", %{"voice" => "Another Custom Azure Voice"})
    |> render_submit()

    assert {:ok, custom} = Providers.get(saved.id)
    assert custom.config == %{expected | "voice" => "Another Custom Azure Voice"}
    assert custom.credential_id == replacement.id
    {:ok, custom_view, _} = live(conn, ~p"/settings/providers/#{saved.id}")
    render_async(custom_view, 10_000)
    assert has_element?(custom_view, "#azure-speech-voice[value='Another Custom Azure Voice']")
    assert Agent.get(counter, & &1) == %{voices: 1, synthesis: 0}
  end

  for {format, mime, disposition} <- [
        {"ogg", "audio/ogg", "inline"},
        {"webm", "audio/webm", "inline"},
        {"amr", "audio/amr", "inline"},
        {"audio", "application/octet-stream", "attachment"},
        {"mp3", "audio/mpeg", "inline"},
        {"opus", "audio/ogg", "inline"},
        {"wav", "audio/wav", "inline"},
        {"pcm", "application/octet-stream", "attachment"},
        {"flac", "audio/flac", "inline"}
      ] do
    @format format
    @mime mime
    @disposition disposition

    test "#{format} Audio Part and native ToolResult render original delivery and endpoint returns exact bytes/name",
         %{tmp_dir: root} do
      session_id = Ecto.UUID.generate()

      operation = %{
        run_id: Ecto.UUID.generate(),
        invocation_id: Ecto.UUID.generate(),
        tool_call_id: "ordinary-azure-display",
        tool_name: "synapsis::tts"
      }

      assert {:ok, descriptor} = Media.put_audio(@audio, @format, root: root)

      assert {:ok, delivery} =
               MediaDelivery.publish(descriptor, session_id, operation,
                 root: root,
                 max_bytes: 4_096
               )

      assert {:ok, path} = MediaDelivery.url(delivery)

      expected = %{
        type: "audio",
        src: path,
        mediaType: @mime,
        filename: "audio.#{@format}"
      }

      assert {:ok, ^expected} = SynapsisWeb.ToolResultView.audio_delivery(descriptor, delivery)

      assert {:ok, result} =
               ResultProjection.to_part(operation.tool_call_id, %{
                 content: [%{type: "text", text: "(spoken) Hello Azure."}],
                 details: %{mediaDescriptor: descriptor, mediaDelivery: delivery}
               })

      audio =
        struct(Synapsis.Part.Audio,
          descriptor: descriptor,
          delivery: delivery,
          name: "Azure Speech"
        )

      for original <- [result, audio] do
        assert {:ok, dump} = Synapsis.Part.dump(original)
        assert {:ok, loaded} = dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
        assert loaded == original

        case loaded do
          %Synapsis.Part.ToolResult{} ->
            assert [%{type: "text", text: "(spoken) Hello Azure."}, ^expected] =
                     SynapsisWeb.ToolResultView.present(loaded).blocks

          %Synapsis.Part.Audio{} ->
            assert {:ok, ^expected} =
                     SynapsisWeb.ToolResultView.audio_delivery(loaded.descriptor, loaded.delivery)
        end
      end

      port = http_listener()

      for _ <- 1..2 do
        {status, headers, bytes} = get_audio(port, path)
        assert status == 200
        assert {"content-type", @mime} in headers
        assert {"content-length", Integer.to_string(byte_size(@audio))} in headers

        assert {"content-disposition", "#{@disposition}; filename=\"audio.#{@format}\""} in headers

        assert bytes == @audio
        assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == descriptor["sha256"]
      end
    end
  end

  defp advanced_config do
    %{
      "voice" => "Custom Current Voice",
      "voiceId" => "Old Alias",
      "voice_id" => "Old Snake Alias",
      "lang" => "fr-FR",
      "outputFormat" => "webm-24khz-16bit-mono-opus",
      "voiceNoteOutputFormat" => "ogg-24khz-16bit-mono-opus",
      "timeoutMs" => 60_000,
      "max_bytes" => 8_192
    }
  end

  defp credential!(label) do
    assert {:ok, credential} =
             Credentials.create(%{
               name: "azure-ui-#{label}-#{Ecto.UUID.generate()}",
               key: "ordinary-azure-ui-fixture"
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

  defp http_listener do
    listener =
      start_supervised!(
        {Gaoxy.HTTP,
         id: __MODULE__,
         plug: {SynapsisServer.Endpoint, []},
         ip: {127, 0, 0, 1},
         port: 0,
         http_limits: %{request_timeout: 5_000}}
      )

    %{local: {:ok, {_address, port}}} = Gaoxy.info(listener, __MODULE__)
    port
  end

  defp get_audio(port, path) do
    assert {:ok, conn} =
             Mint.HTTP.connect(:http, "127.0.0.1", port,
               mode: :passive,
               protocols: [:http1],
               transport_opts: [timeout: 5_000]
             )

    try do
      assert {:ok, conn, ref} = Mint.HTTP.request(conn, "GET", path, [], nil)
      receive_audio(conn, ref, System.monotonic_time(:millisecond) + 5_000, nil, [], [])
    after
      Mint.HTTP.close(conn)
    end
  end

  defp receive_audio(conn, ref, deadline, status, headers, body) do
    remaining = deadline - System.monotonic_time(:millisecond)
    assert remaining > 0, "timed out waiting for ordinary audio delivery"
    assert {:ok, conn, responses} = Mint.HTTP.recv(conn, 0, remaining)

    {status, headers, body} =
      Enum.reduce(responses, {status, headers, body}, fn
        {:status, ^ref, value}, {_status, headers, body} -> {value, headers, body}
        {:headers, ^ref, value}, {status, headers, body} -> {status, headers ++ value, body}
        {:data, ^ref, value}, {status, headers, body} -> {status, headers, [body, value]}
        _, acc -> acc
      end)

    if {:done, ref} in responses,
      do: {status, headers, IO.iodata_to_binary(body)},
      else: receive_audio(conn, ref, deadline, status, headers, body)
  end
end
