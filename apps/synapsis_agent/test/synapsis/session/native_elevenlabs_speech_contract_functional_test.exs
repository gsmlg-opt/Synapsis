defmodule Synapsis.Session.NativeElevenLabsSpeechContractFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Agent.MediaDelivery
  alias Synapsis.Agent.Tools.TTS
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.{Speech.ElevenLabs, ToolName}
  alias Synapsis.Runtime.Store, as: RuntimeStore
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}
  alias Synapsis.Workspace.Media
  alias Synapsis.{AgentConfigs, Credentials, Models, Providers}

  @moduletag :tmp_dir
  @moduletag timeout: 90_000
  @name "synapsis::tts"
  @call_id "ordinary-tts"
  @text "Hello ElevenLabs & <world>.\n \"Speak\" 'clearly' 🌍"
  @spoken "(spoken) " <> @text
  # Valid local media constants are immutable test inputs, independent of
  # production. No /tmp files, codec processes, or real provider are needed.
  @mp3 Base.decode64!(
         "SUQzBAAAAAAAI1RTU0UAAAAPAAADTGF2ZjYyLjEyLjEwMgAAAAAAAAAAAAAA//OEwAAAAAAAAAAAAEluZm8AAAAPAAAABwAAA2AAVVVVVVVVVVVVVVVVVVVxcXFxcXFxcXFxcXFxcY6Ojo6Ojo6Ojo6Ojo6Oqqqqqqqqqqqqqqqqqqqqx8fHx8fHx8fHx8fHx8fj4+Pj4+Pj4+Pj4+Pj4///////////////////AAAAAExhdmM2Mi4yOAAAAAAAAAAAAAAAACQEIAAAAAAAAANgrF8r0wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA//NExAARgE6kX08YAAHv+2/AQ9D0PQ80zrVa4IIBnAzgqwkYm5L1Gzx4gIAgCAYicPvygYy4P8EHTnBN+J3cv7un3dPuxAAwfw+CByoBh/gh0+4gCSDCCAQAAI3Fnt1N//NExA0ViT6c15tQAFCYaqHeFgwXnkgwJLDxC0ycOLbPb18+ASgMgK/iCBuBuFX/ESIkiHw+/8hHo9Ih8Pv/yEej04fD43+CoiCoK/8sFQVEQVBX/8sqLnJXLrMAaAMz//NExAkUyFosAd8AAACIATMAyAITArwbQwZwSAMDUB9zBbwoo3GVFuMjOCgTBlwaAwOEDSMDvAfDAJAEcwCAAhMAgABwSAFF8l/S3////////9X////01YmsIXDMIKMy//NExAgS+F4cANf4JJTgYDArwUcxG0bNMFiALzBRxH06GTP3MXrCbzmjOM+mEx4MjD4bMIA4wSBy5adD92P1/+5enR9n/q/+32/+n5PT72ccYAtt2//wAGff1SOhOO4+//NExA8WOba1v1owAooOZukX8ZJSbzz+A37l+denp6e2hGPd3dxGPd69kEMe7/sghl3rYeACGXetlkCGXfbLIIZd+Msghj34xyCGPvjHIBgmUcGOUdwxjAAAFotFotFA//NExAkUAT7aX5OIAqBAAAAARVBGomijjUC6KuMQr+FUCKBbMckqFni3icBO5EzFA6j44BmyfIgRdlo1/L5OEXMy4X16/9MuF9aBmv+CYkC4jb/qTEFNRTMuMTAwVVVV//NExAwAAANIAcAAAFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV"
       )
  @opus Base.decode64!(
          "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"
        )
  @wav Base.decode64!(
         "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"
       )

  # Literal ordinary requests cover default preparation, saved settings,
  # Agent overlays, all three published codecs and tool > Agent > default T.
  for {id, model, voice, format, options, input, timeout, base_path} <- [
        {"default-mp3", "eleven_multilingual_v2", "pMsXgVXv3BLzUgSXRplE", "mp3", %{},
         %{"text" => @text}, 30_000, "/"},
        {"saved-opus", "eleven_flash_v2_5", "SavedVoice1234567", "opus",
         %{"output_format" => "opus_48000_64"}, %{"text" => @text}, 30_000, "/Tenant///"},
        {"saved-wav", "eleven_v3", "SavedVoice1234567", "wav",
         %{"output_format" => "wav_44100", "latency_tier" => 2}, %{"text" => @text}, 30_000,
         "/Tenant/Speech///"},
        {"agent45000", "eleven_flash_v2", "AgentVoice1234567", "mp3",
         %{
           "model_id" => " eleven_turbo_v2 ",
           "voice_id" => " AgentVoice1234567 ",
           "timeout_ms" => 45_000,
           "seed" => 29,
           "apply_text_normalization" => " OFF ",
           "language_code" => " JA ",
           "voice_settings" => %{"speed" => 1.25, "style" => 0.4}
         }, %{"text" => @text}, 45_000, "/Current/Agent///"},
        {"tool75000", "eleven_flash_v2_5", "SavedVoice1234567", "opus",
         %{"timeout_ms" => 45_000, "output_format" => "opus_48000_64", "latency_tier" => 1},
         %{"text" => "  " <> @text <> "  ", "channel" => "", "timeoutMs" => 75_000}, 75_000,
         "/Current/Tool///"},
        {"custom-model", "__custom__", "CustomVoice1234567", "wav",
         %{"output_format" => "wav_22050"}, %{"text" => @text}, 30_000, "/Custom/Speech///"}
      ] do
    saved = %{
      "modelId" => if(id == "saved-wav", do: " eleven_v3 ", else: " eleven_turbo_v2_5 "),
      "voiceId" => " SavedVoice1234567 ",
      "seed" => 17,
      "applyTextNormalization" => " ON ",
      "languageCode" => " EN ",
      "voiceSettings" => %{
        "stability" => 0.2,
        "similarityBoost" => 0.9,
        "style" => 0.3,
        "useSpeakerBoost" => false,
        "speed" => 1.1
      },
      "timeoutMs" => 60_000,
      "timeout_ms" => 90_000,
      "max_bytes" => 65_536,
      "advanced_fixture" => %{"labels" => ["preserve", "all"]}
    }

    saved =
      case id do
        "default-mp3" ->
          Map.take(saved, ~w(timeoutMs timeout_ms max_bytes advanced_fixture))

        "custom-model" ->
          Map.merge(saved, %{"modelId" => " __custom__ ", "voiceId" => " CustomVoice1234567 "})

        _ ->
          saved
      end

    settings =
      cond do
        id == "default-mp3" ->
          %{
            "stability" => 0.5,
            "similarity_boost" => 0.75,
            "style" => 0,
            "use_speaker_boost" => true,
            "speed" => 1
          }

        id == "agent45000" ->
          %{
            "stability" => 0.2,
            "similarity_boost" => 0.9,
            "style" => 0.4,
            "use_speaker_boost" => false,
            "speed" => 1.25
          }

        true ->
          %{
            "stability" => 0.2,
            "similarity_boost" => 0.9,
            "style" => 0.3,
            "use_speaker_boost" => false,
            "speed" => 1.1
          }
      end

    body = %{"text" => @text, "model_id" => model, "voice_settings" => settings}

    body =
      cond do
        id == "default-mp3" ->
          body

        id == "agent45000" ->
          Map.merge(body, %{
            "seed" => 29,
            "apply_text_normalization" => "off",
            "language_code" => "ja"
          })

        true ->
          Map.merge(body, %{
            "seed" => 17,
            "apply_text_normalization" => "on",
            "language_code" => "en"
          })
      end

    output_format = Map.get(options, "output_format", "mp3_44100_128")
    query = %{"output_format" => output_format}

    query =
      if id == "tool75000", do: Map.put(query, "optimize_streaming_latency", "1"), else: query

    @provider_fixture %{
      id: id,
      base_path: base_path,
      endpoint_path: String.trim_trailing(base_path, "/") <> "/v1/text-to-speech/" <> voice,
      config: saved,
      format: format,
      output_format: output_format,
      query: query,
      mime: %{"mp3" => "audio/mpeg", "opus" => "audio/ogg", "wav" => "audio/wav"}[format],
      audio: %{"mp3" => @mp3, "opus" => @opus, "wav" => @wav}[format],
      timeout: timeout,
      allowance: timeout + 5_000,
      model: model,
      voice: voice,
      body: body
    }
    @options options
    @input input
    @audio @provider_fixture.audio
    @format format
    @mime @provider_fixture.mime
    test "selected TTS with #{id} settles durable audio and replays success through a new Worker",
         %{tmp_dir: root} do
      h = harness(root, @options, @provider_fixture)
      audio = @audio
      install(h, @input)
      trace_effects()
      start(h)

      assert_receive {:tts_outer, 0, initial}, 5_000
      assert_receive {:tts_descriptor, descriptor, locator}, 5_000
      assert descriptor.backend == TTS
      assert descriptor.codex_exposure == :direct_model_only
      assert descriptor.backend_context.provider_id == h.speech.id
      assert descriptor.backend_context.provider_name == h.speech.name
      assert [%{"name" => name, "input_schema" => schema}] = initial["tools"]
      assert ToolName.decode(name) == @name
      assert schema == descriptor.schema
      assert schema["type"] == "object"
      assert schema["required"] == ["text"]
      assert Map.keys(schema["properties"]) |> Enum.sort() == ~w(channel text timeoutMs)
      assert schema["properties"]["text"]["type"] == "string"
      assert schema["properties"]["channel"]["type"] == "string"
      assert schema["properties"]["timeoutMs"]["type"] == "integer"
      assert schema["additionalProperties"] == false
      assert {:ok, []} = Models.list(provider_id: h.speech.id)

      assert_receive {:tts_speech, request}, 10_000

      assert request == @provider_fixture.body

      assert_receive {:tts_outer, 1, following}, 10_000
      assert_receive {:tts_native_settled, [native]}, 5_000
      assert native.is_error == false
      assert native.content == [%{type: "text", text: @spoken}]
      assert_receive {:run_event, %{type: "session.completed"}}, 20_000

      [use, result] = tts_parts(h.session.id)

      refute Enum.any?(Synapsis.Message.list_by_session(h.session.id), fn message ->
               Enum.any?(message.parts, &match?(%Synapsis.Part.Audio{}, &1))
             end)

      assert %ToolUse{tool: @name, tool_use_id: @call_id} = use
      assert use.input == @input
      assert %ToolResult{is_error: false, tool_use_id: @call_id, content: @spoken} = result
      projected = result.projection["result"]
      assert projected["content"] == [%{"type" => "text", "text" => @spoken}]
      assert projected["details"] == Jason.decode!(Jason.encode!(native.details))
      details = projected["details"]
      assert details["provider"] == "elevenlabs"
      assert Map.get(details, "timeoutMs") == @input["timeoutMs"]
      assert Map.has_key?(details, "timeoutMs") == Map.has_key?(@input, "timeoutMs")
      descriptor = details["mediaDescriptor"]
      uri = descriptor["uri"]
      sha256 = Base.encode16(:crypto.hash(:sha256, audio), case: :lower)
      assert uri == "synapsis-media://audio/" <> sha256 <> "." <> @format

      assert descriptor == %{
               "uri" => uri,
               "sha256" => sha256,
               "byte_size" => byte_size(audio),
               "mime_type" => @mime,
               "format" => @format
             }

      assert details["audioPath"] == uri
      assert details["media"] == %{"mediaUrl" => uri, "trustedLocalMedia" => true}

      delivery = details["mediaDelivery"]
      assert %{"version" => 1, "session_id" => session_id, "id" => delivery_id} = delivery
      assert session_id == h.session.id
      assert map_size(delivery) == 3
      assert {:ok, ^delivery_id} = Ecto.UUID.cast(delivery_id)
      assert {:ok, "/api/media/audio/" <> delivery_path} = MediaDelivery.url(delivery)
      assert delivery_path == session_id <> "/" <> delivery_id
      assert {:ok, fact} = RuntimeStore.get_fact(session_id, :audio_delivery, delivery_id)
      assert fact.version == 1
      assert fact.descriptor == descriptor
      assert fact.root == h.media_root
      assert fact.max_bytes == h.max_bytes
      assert fact.invocation.tool_call_id == @call_id
      assert fact.invocation.tool_name == @name

      assert {:ok, %{audio: ^audio, descriptor: ^descriptor}} =
               MediaDelivery.read(session_id, delivery_id)

      assert {:ok, %{audio: ^audio, descriptor: ^descriptor}} =
               Media.read_audio(uri, root: h.media_root)

      assert [audio_path] = Path.wildcard(Path.join(h.media_root, "**/*.#{@format}"))
      audio_stat = File.stat!(audio_path, time: :posix)
      assert File.read!(audio_path) == audio
      assert_text_wire(following, @input)
      assert_round_trip_and_store(h.session.id, [use, result], root, audio)
      aggregate = assert_runtime_aggregate(locator, native)

      assert {:ok, _} =
               Providers.update(h.speech.id, %{
                 base_url: Gaoxy.Test.url(h.speech_fixture, "/Changed/After/Completion"),
                 config: %{
                   "modelId" => "eleven_v3",
                   "voiceId" => "LaterVoice1234567",
                   "voiceSettings" => %{"speed" => 0.9}
                 }
               })

      assert {:ok, _} =
               AgentConfigs.update(h.configured_agent, %{
                 config:
                   Map.put(
                     h.configured_agent.config,
                     "tts",
                     Map.merge(h.tts, %{
                       "media_root" => Path.join(root, "new-audio-root"),
                       "max_bytes" => 131_072,
                       "model_id" => "eleven_v3",
                       "voice_id" => "LaterAgent1234567",
                       "output_format" => "wav_44100",
                       "voice_settings" => %{"speed" => 1.1}
                     })
                   )
               })

      [{old, _}] = Registry.lookup(Synapsis.Session.Registry, h.session.id)
      monitor = Process.monitor(old)
      assert :ok = DynamicSupervisor.stop_session(h.session.id)
      assert_receive {:DOWN, ^monitor, :process, ^old, _}, 5_000
      SessionHarness.ensure_running!(h.session.id)
      [{new, _}] = Registry.lookup(Synapsis.Session.Registry, h.session.id)
      refute new == old
      assert :ok = Worker.send_message(h.session.id, "Recall the completed speech")
      assert_receive {:tts_outer, 2, replay}, 10_000
      assert_receive {:run_event, %{type: "session.completed"}}, 20_000
      assert_text_wire(replay, @input)
      assert tts_parts(h.session.id) == [use, result]
      assert_round_trip_and_store(h.session.id, [use, result], root, audio)
      assert {:ok, ^fact} = RuntimeStore.get_fact(session_id, :audio_delivery, delivery_id)
      assert {:ok, [^fact]} = RuntimeStore.list_facts(session_id, :audio_delivery)

      assert {:ok, %{audio: ^audio, descriptor: ^descriptor}} =
               MediaDelivery.read(session_id, delivery_id)

      assert {:ok, %{audio: ^audio, descriptor: ^descriptor}} =
               Media.read_audio(uri, root: h.media_root)

      replay_stat = File.stat!(audio_path, time: :posix)

      assert {replay_stat.inode, replay_stat.mtime, replay_stat.size} ==
               {audio_stat.inode, audio_stat.mtime, audio_stat.size}

      assert File.read!(audio_path) == audio
      assert %{speech: 1, outer: 3} = Agent.get(h.counter, & &1)
      assert {:ok, ^aggregate} = RuntimeStore.load(locator.namespace, locator.run_id)
      assert_once_each_effect(h, @input, descriptor, delivery, fact)

      assert %{entries: [entry], dropped: 0, cursor: 1, truncated: false} =
               Gaoxy.Test.requests(h.speech_fixture)

      assert entry.method == "POST"
      assert entry.path == h.speech_endpoint
      assert entry.outcome == :ok
      assert entry.body.complete == true
      assert entry.body.truncated == false
      assert Jason.decode!(entry.body.data) == h.expected_body
      export_projection(h, use, result, descriptor, delivery, fact)
    end
  end

  defp harness(root, options, provider_fixture) do
    h =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(h) end)
    fixture = Gaoxy.Test.open(capture_body: 8_192)
    on_exit(fn -> Gaoxy.Test.close(fixture) end)

    assert {:ok, credential} =
             Credentials.create(%{
               name: "tts-elevenlabs-credential-#{Ecto.UUID.generate()}",
               key: "initial-elevenlabs-speech-fixture"
             })

    on_exit(fn -> Credentials.delete(credential.id) end)

    assert {:ok, replacement} =
             Credentials.create(%{
               name: "tts-elevenlabs-current-#{Ecto.UUID.generate()}",
               key: "replacement-elevenlabs-speech-fixture"
             })

    on_exit(fn -> Credentials.delete(replacement.id) end)

    assert {:ok, speech} =
             Providers.create(%{
               name: "tts-elevenlabs-speech-#{Ecto.UUID.generate()}",
               type: "elevenlabs",
               preset: "elevenlabs",
               base_url: Gaoxy.Test.url(fixture, "/Stale/Root"),
               credential_id: credential.id,
               config: %{"voiceId" => "StaleVoice1234567"}
             })

    on_exit(fn -> Providers.delete(speech.id) end)

    # Rotate the same UUID before preparation, preserving selected-tool admission.
    assert {:ok, _} =
             Providers.update(speech.id, %{
               base_url: Gaoxy.Test.url(fixture, provider_fixture.base_path),
               credential_id: replacement.id,
               config: provider_fixture.config
             })

    assert {:ok, _} =
             Credentials.update(
               replacement.id,
               %{key: "current-elevenlabs-speech-fixture"}
             )

    assert {:ok, speech} = Providers.get(speech.id)
    assert speech.credential_id == replacement.id
    assert speech.config == provider_fixture.config
    assert speech.api_key_encrypted == "current-elevenlabs-speech-fixture"
    media_root = Path.join(root, "durable-audio")
    tts = Map.merge(%{"provider" => speech.name, "media_root" => media_root}, options)
    config = Map.put(h.agent_config.config, "tts", tts)

    assert {:ok, configured_agent} =
             AgentConfigs.update(
               h.agent_config,
               %{tools: [@name], config: config}
             )

    assert :ok =
             Synapsis.Provider.Registry.register(
               h.provider.name,
               %{type: "anthropic", base_url: h.provider.base_url, api_key: "fixture"}
             )

    Agent.update(h.counter, &Map.merge(&1, %{speech: 0, outer: 0}))

    Map.merge(h, %{
      speech: speech,
      current_saved_config: provider_fixture.config,
      fixture_id: provider_fixture.id,
      configured_agent: configured_agent,
      tts: tts,
      speech_fixture: fixture,
      speech_endpoint: provider_fixture.endpoint_path,
      expected_root:
        String.trim_trailing(Gaoxy.Test.url(fixture, provider_fixture.base_path), "/"),
      expected_query: provider_fixture.query,
      media_root: media_root,
      synthesis_timeout: provider_fixture.timeout,
      expected_body: provider_fixture.body,
      expected_model: provider_fixture.model,
      expected_voice: provider_fixture.voice,
      output_format: provider_fixture.output_format,
      allowance: provider_fixture.allowance,
      audio: provider_fixture.audio,
      format: provider_fixture.format,
      mime: provider_fixture.mime,
      max_bytes: Map.get(options, "max_bytes", provider_fixture.config["max_bytes"])
    })
  end

  defp install(h, input) do
    owner = self()

    Gaoxy.Test.stub(h.speech_fixture, "POST", h.speech_endpoint, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params == h.expected_query
      assert Plug.Conn.get_req_header(conn, "xi-api-key") == ["current-elevenlabs-speech-fixture"]
      if h.format == "mp3", do: assert(Plug.Conn.get_req_header(conn, "accept") == ["audio/mpeg"])
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      Agent.update(h.counter, &Map.update!(&1, :speech, fn n -> n + 1 end))
      send(owner, {:tts_speech, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type(h.mime)
      |> Plug.Conn.resp(200, h.audio)
    end)

    Gaoxy.Test.stub(h.provider.fixture, "POST", "/v1/messages", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      index =
        Agent.get_and_update(h.counter, fn state ->
          {state.outer, %{state | outer: state.outer + 1}}
        end)

      send(owner, {:tts_outer, index, request})

      if index in [0, 1] do
        [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, h.session.id)
        {_, data} = :sys.get_state(worker, 1_000)
        adapter = :sys.get_state(data.runtime_pid, 1_000)
        native = :sys.get_state(adapter.root, 1_000)

        if index == 0,
          do:
            send(
              owner,
              {:tts_descriptor, native.catalog.registry.tools[@name],
               %{namespace: adapter.store.namespace, run_id: adapter.run_id}}
            ),
          else: send(owner, {:tts_native_settled, Map.values(native.run.tool_results)})
      end

      outer_response(conn, if(index == 0, do: input))
    end)
  end

  defp start(h) do
    SessionHarness.subscribe!(h.session.id)
    SessionHarness.ensure_running!(h.session.id)
    assert :ok = Worker.send_message(h.session.id, "Speak the ordinary fixture text")
  end

  defp outer_response(conn, input) do
    {block, delta, stop} =
      if input do
        {%{
           "type" => "tool_use",
           "id" => @call_id,
           "name" => ToolName.encode(@name),
           "input" => %{}
         }, %{"type" => "input_json_delta", "partial_json" => Jason.encode!(input)}, "tool_use"}
      else
        {%{"type" => "text", "text" => ""},
         %{"type" => "text_delta", "text" => "Speech result received"}, "end_turn"}
      end

    events = [
      %{"type" => "content_block_start", "index" => 0, "content_block" => block},
      %{"type" => "content_block_delta", "index" => 0, "delta" => delta},
      %{"type" => "content_block_stop", "index" => 0},
      %{"type" => "message_delta", "delta" => %{"stop_reason" => stop}},
      %{"type" => "message_stop"}
    ]

    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.resp(200, Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n")))
  end

  defp tts_parts(id),
    do:
      for(
        message <- Synapsis.Message.list_by_session(id),
        part <- message.parts,
        match?(%ToolUse{tool: @name}, part) or match?(%ToolResult{tool_use_id: @call_id}, part),
        do: part
      )

  defp assert_text_wire(request, input) do
    blocks =
      Enum.flat_map(request["messages"], &List.wrap(&1["content"])) |> Enum.filter(&is_map/1)

    assert [use] = Enum.filter(blocks, &(&1["type"] == "tool_use"))
    assert use["id"] == @call_id
    assert ToolName.decode(use["name"]) == @name
    assert use["input"] == input
    assert [result] = Enum.filter(blocks, &(&1["type"] == "tool_result"))
    assert result["tool_use_id"] == @call_id
    assert result["is_error"] == false
    assert result["content"] == [%{"type" => "text", "text" => @spoken}]
  end

  defp assert_runtime_aggregate(locator, native) do
    assert {:ok, aggregate} = RuntimeStore.load(locator.namespace, locator.run_id)
    assert aggregate.run.state == :completed
    assert Map.values(aggregate.run.tool_results) == [native]

    assert [intent] =
             aggregate.run.execution_intents |> Map.values() |> Enum.filter(&(&1.type == :tool))

    assert intent.operation.tool_name == @name
    assert intent.operation.tool_call_id == @call_id
    assert intent.operation.run_id == locator.run_id
    aggregate
  end

  defp assert_round_trip_and_store(id, [use, result] = parts, _root, _audio) do
    for part <- parts do
      assert {:ok, dump} = Synapsis.Part.dump(part)
      assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
    end

    await_native_ready(id, System.monotonic_time(:millisecond) + 5_000)
    snapshot = Worker.snapshot(id)
    assert snapshot.source == :live
    assert snapshot.status == :waiting
    assert snapshot.error == nil
    assert snapshot.session.id == id

    assert {:ok, turns} = Store.list_turns(id)

    for {turn, index} <- Enum.with_index(turns),
        do: assert({:ok, ^turn} = Store.get_turn(id, index))

    assert [stored_use] =
             for(turn <- turns, part <- turn.parts, part[:type] == "tool_use", do: part)

    assert stored_use.name == use.tool
    assert stored_use.id == use.tool_use_id
    assert stored_use.input == use.input

    assert [stored] =
             for(turn <- turns, part <- turn.parts, part[:type] == "tool_result", do: part)

    assert stored.content == result.content
    assert stored.projection == result.projection
  end

  # Completion is published before the Worker's normal pending-input read lane.
  # Observe the public readiness state before inspecting the completed snapshot.
  defp await_native_ready(id, deadline) do
    status = Worker.public_status(id, deadline: deadline)

    case status do
      {:ok, %{runtime: %{phase: "idle", active: false}}} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            10 -> await_native_ready(id, deadline)
          end
        else
          flunk("Worker did not finish its ordinary readiness lane: #{inspect(status)}")
        end
    end
  end

  defp trace_effects do
    calls = [
      {TTS, :execute, 1},
      {Providers, :elevenlabs_speech_config, 2},
      {ElevenLabs, :synthesize, 2},
      {ElevenLabs, :build_request, 2},
      {ElevenLabs, :resolve_config, 1},
      {Synapsis.Provider.Speech.Opus, :transcode, 2},
      {Req, :request, 1},
      {Media, :put_audio, 3},
      {MediaDelivery, :publish, 4}
    ]

    for {module, function, arity} <- calls do
      Code.ensure_loaded!(module)
      spec = if module in [ElevenLabs, Providers], do: [{:_, [], [{:return_trace}]}], else: true
      :erlang.trace_pattern({module, function, arity}, spec, [:local])
    end

    :erlang.trace_pattern(
      {GenServer, :call, 3},
      [{[:_, {:effect_deadline, :_}, :_], [], [{:return_trace}]}],
      [:local]
    )

    :erlang.trace(:all, true, [:call, {:tracer, self()}])

    on_exit(fn ->
      :erlang.trace(:all, false, [:call])
      for mfa <- calls ++ [{GenServer, :call, 3}], do: :erlang.trace_pattern(mfa, false, [:local])
    end)
  end

  defp traced_calls do
    barrier = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^barrier}, 5_000
    drain_calls([])
  end

  defp drain_calls(calls) do
    receive do
      {:trace, pid, :call, {module, function, arguments}} ->
        drain_calls([{pid, module, function, arguments} | calls])

      {:trace, pid, :return_from, {module, function, _arity}, result} ->
        drain_calls([{:returned, pid, module, function, result} | calls])
    after
      0 -> Enum.reverse(calls)
    end
  end

  defp assert_once_each_effect(h, _input, descriptor, delivery, fact) do
    calls = traced_calls()

    assert [{effect, ElevenLabs, :synthesize, [request, config]}] =
             Enum.filter(calls, &match?({_, ElevenLabs, :synthesize, _}, &1))

    assert [{^effect, TTS, :execute, [operation]}] =
             Enum.filter(calls, &match?({_, TTS, :execute, _}, &1))

    assert is_function(operation.backend_context.effect_deadline, 0)
    assert operation.backend_context.provider_id == h.speech.id
    assert operation.backend_context.provider_name == h.speech.name

    prepared =
      for {:returned, _, Providers, :elevenlabs_speech_config, {:ok, value}} <- calls,
          do: value

    assert prepared != []

    for speech <- prepared do
      assert speech.provider_id == h.speech.id
      assert speech.provider_name == h.speech.name
      assert {:ok, _} = Ecto.UUID.cast(speech.provider_id)
    end

    deadlines = for {:returned, ^effect, GenServer, :call, {:ok, value}} <- calls, do: value
    assert length(deadlines) >= 3
    [native | _] = deadlines

    for deadline <- deadlines do
      assert deadline.selected_timeout_ms == h.allowance
      assert deadline.paused == false
      assert deadline.remaining_ms > 0
      assert deadline.remaining_ms <= h.allowance
      assert deadline.deadline_ms == native.deadline_ms
    end

    assert request.text == @text
    assert request.target == :audio_file
    assert request.timeout_ms == h.synthesis_timeout
    assert request.deadline_ms == native.deadline_ms
    refute Map.has_key?(config, :timeout_ms)
    refute Map.has_key?(config, :timeoutMs)
    assert config.model_id == h.expected_model
    assert config.voice_id == h.expected_voice
    assert config.max_bytes == h.max_bytes
    assert config.api_key == "current-elevenlabs-speech-fixture"

    assert config.base_url ==
             h.expected_root

    assert Enum.any?(calls, &match?({_, ElevenLabs, :resolve_config, _}, &1))
    refute Enum.any?(calls, &match?({_, Synapsis.Provider.Speech.Opus, :transcode, _}, &1))
    built = for {:returned, ^effect, ElevenLabs, :build_request, {:ok, value}} <- calls, do: value

    assert Enum.any?(built, fn built ->
             uri = URI.parse(built.url)

             built.body == h.expected_body and built.timeout_ms == h.synthesis_timeout and
               built[:deadline_ms] == native.deadline_ms and uri.path == h.speech_endpoint and
               URI.decode_query(uri.query) == h.expected_query
           end)

    assert [{:returned, ^effect, ElevenLabs, :synthesize, {:ok, output}}] =
             Enum.filter(calls, &match?({:returned, ^effect, ElevenLabs, :synthesize, _}, &1))

    assert output == %{
             audio: h.audio,
             output_format: h.output_format,
             file_extension: "." <> h.format,
             voice_compatible: h.format == "opus",
             media_format: h.format
           }

    http =
      for {_, Req, :request, [%Req.Request{} = req]} <- calls,
          req.url.path == h.speech_endpoint,
          do: req

    assert [http_request] = http

    for timeout <- [
          http_request.options[:receive_timeout],
          http_request.options[:request_timeout],
          http_request.options[:finch][:pool_timeout]
        ] do
      assert is_integer(timeout) and timeout > 0 and timeout <= h.synthesis_timeout
    end

    assert [{^effect, Media, :put_audio, [audio, format, opts]}] =
             Enum.filter(calls, &match?({_, Media, :put_audio, _}, &1))

    assert audio == h.audio
    assert format == h.format
    assert opts[:root] == h.media_root
    assert opts[:max_bytes] == h.max_bytes
    assert opts[:deadline] == native.deadline_ms

    assert [
             {^effect, MediaDelivery, :publish,
              [^descriptor, session_id, published_operation, delivery_opts]}
           ] =
             Enum.filter(calls, &match?({_, MediaDelivery, :publish, _}, &1))

    assert session_id == h.session.id
    assert delivery_opts[:root] == h.media_root
    assert delivery_opts[:max_bytes] == h.max_bytes

    assert fact.invocation ==
             Map.take(
               published_operation,
               [:run_id, :invocation_id, :tool_call_id, :tool_name]
             )

    assert {:ok, ^fact} = RuntimeStore.get_fact(session_id, :audio_delivery, delivery["id"])

    assert Enum.find_index(calls, &match?({_, Req, :request, _}, &1)) <
             Enum.find_index(calls, &match?({^effect, Media, :put_audio, _}, &1))

    assert Enum.find_index(calls, &match?({^effect, Media, :put_audio, _}, &1)) <
             Enum.find_index(calls, &match?({^effect, MediaDelivery, :publish, _}, &1))
  end

  defp export_projection(h, use, result, descriptor, delivery, fact) do
    assert {:ok, use_dump} = Synapsis.Part.dump(use)
    assert {:ok, result_dump} = Synapsis.Part.dump(result)
    assert {:ok, turns} = Store.list_turns(h.session.id)

    assert [stored] =
             for(turn <- turns, part <- turn.parts, part[:type] == "tool_result", do: part)

    assert {:ok, history_result} =
             stored |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()

    assert history_result == result
    assert {:ok, history_dump} = Synapsis.Part.dump(history_result)

    # Native TTS persists a ToolResult. The shared Audio Part consumer receives
    # that same checked native descriptor/reference, without another publication.
    audio_part = fn part ->
      details = part.projection["result"]["details"]

      audio =
        struct(Synapsis.Part.Audio,
          descriptor: details["mediaDescriptor"],
          delivery: details["mediaDelivery"],
          name: "ElevenLabs"
        )

      assert {:ok, dump} = Synapsis.Part.dump(audio)

      assert {:ok, ^audio} =
               dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()

      dump
    end

    evidence = System.get_env("ELEVENLABS344_NATIVE_EXPORT")

    if evidence && h.fixture_id in ["default-mp3", "saved-opus", "saved-wav"] do
      File.write!(
        Path.join(evidence, "native-#{h.fixture_id}-projection.json"),
        Jason.encode!(
          %{
            rowId: h.fixture_id,
            format: h.format,
            descriptor: descriptor,
            delivery: delivery,
            deliveryFact: fact,
            originalRoot: h.media_root,
            originalMaxBytes: h.max_bytes,
            audioBase64: Base.encode64(h.audio),
            toolUse: use_dump,
            initial: %{toolResult: result_dump, audioPart: audio_part.(result)},
            history: %{toolResult: history_dump, audioPart: audio_part.(history_result)}
          },
          pretty: true
        )
      )
    end
  end
end
