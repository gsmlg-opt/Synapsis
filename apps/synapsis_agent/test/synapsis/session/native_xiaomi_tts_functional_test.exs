defmodule Synapsis.Session.NativeXiaomiTTSFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Agent.MediaDelivery
  alias Synapsis.Agent.Tools.{DisplayCatalog, Profiles, TTS}
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.{Speech.Xiaomi, ToolName}
  alias Synapsis.Runtime.Store, as: RuntimeStore
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}
  alias Synapsis.Workspace.Media
  alias Synapsis.{AgentConfigs, Credentials, Models, Providers}

  @moduletag :tmp_dir
  @moduletag timeout: 90_000
  @name "synapsis::tts"
  @call_id "ordinary-tts"
  @text "Hello Xiaomi & <world>.\n \"Speak\" 'clearly' 🌍"
  @spoken "(spoken) " <> @text
  # Independent valid media constants; tests do not load external runtime fixtures.
  @mp3 Base.decode64!(
         "SUQzBAAAAAAAI1RTU0UAAAAPAAADTGF2ZjYyLjEyLjEwMgAAAAAAAAAAAAAA//OEwAAAAAAAAAAAAEluZm8AAAAPAAAABwAAA2AAVVVVVVVVVVVVVVVVVVVxcXFxcXFxcXFxcXFxcY6Ojo6Ojo6Ojo6Ojo6Oqqqqqqqqqqqqqqqqqqqqx8fHx8fHx8fHx8fHx8fj4+Pj4+Pj4+Pj4+Pj4///////////////////AAAAAExhdmM2Mi4yOAAAAAAAAAAAAAAAACQEIAAAAAAAAANgrF8r0wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA//NExAARgE6kX08YAAHv+2/AQ9D0PQ80zrVa4IIBnAzgqwkYm5L1Gzx4gIAgCAYicPvygYy4P8EHTnBN+J3cv7un3dPuxAAwfw+CByoBh/gh0+4gCSDCCAQAAI3Fnt1N//NExA0ViT6c15tQAFCYaqHeFgwXnkgwJLDxC0ycOLbPb18+ASgMgK/iCBuBuFX/ESIkiHw+/8hHo9Ih8Pv/yEej04fD43+CoiCoK/8sFQVEQVBX/8sqLnJXLrMAaAMz//NExAkUyFosAd8AAACIATMAyAITArwbQwZwSAMDUB9zBbwoo3GVFuMjOCgTBlwaAwOEDSMDvAfDAJAEcwCAAhMAgABwSAFF8l/S3////////9X////01YmsIXDMIKMy//NExAgS+F4cANf4JJTgYDArwUcxG0bNMFiALzBRxH06GTP3MXrCbzmjOM+mEx4MjD4bMIA4wSBy5adD92P1/+5enR9n/q/+32/+n5PT72ccYAtt2//wAGff1SOhOO4+//NExA8WOba1v1owAooOZukX8ZJSbzz+A37l+denp6e2hGPd3dxGPd69kEMe7/sghl3rYeACGXetlkCGXfbLIIZd+Msghj34xyCGPvjHIBgmUcGOUdwxjAAAFotFotFA//NExAkUAT7aX5OIAqBAAAAARVBGomijjUC6KuMQr+FUCKBbMckqFni3icBO5EzFA6j44BmyfIgRdlo1/L5OEXMy4X16/9MuF9aBmv+CYkC4jb/qTEFNRTMuMTAwVVVV//NExAwAAANIAcAAAFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV"
       )
  @wav Base.decode64!(
         "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"
       )
  @design_style "Warm, natural, and friendly voice with clear pronunciation and conversational pacing."

  # Literal source337 wire expectations, fixed before host implementation or RED execution.
  for {id, label, options, input, saved, model, voice, style, format, timeout, allowance,
       base_path} <- [
        {"default-mp3", "default MP3 native35000", %{}, %{"text" => @text}, %{}, "mimo-v2.5-tts",
         "mimo_default", nil, "mp3", 30_000, 35_000, "/v1///"},
        {"saved-source-wav", "saved source aliases WAV ignore saved60000", %{},
         %{"text" => @text},
         %{
           "modelId" => " mimo-v2.5-tts ",
           "speakerVoiceId" => " Chloe ",
           "voice" => "Milo",
           "voiceId" => "Dean",
           "format" => " WaV ",
           "style" => " 轻柔、清晰。 ",
           "timeoutMs" => 60_000
         }, "mimo-v2.5-tts", "Chloe", "轻柔、清晰。", "wav", 30_000, 35_000, "/custom/Xiaomi/v7///"},
        {"saved-canonical-mp3", "saved canonical aliases MP3 retain custom values", %{},
         %{"text" => @text, "channel" => "  "},
         %{
           "model_id" => " experimental-tts-v9 ",
           "speaker_voice_id" => " My Custom Voice ",
           "voice_id" => "Dean",
           "format" => " mP3 ",
           "style" => " Gentle\nclear ",
           "timeout_ms" => 60_000
         }, "experimental-tts-v9", "My Custom Voice", "Gentle\nclear", "mp3", 30_000, 35_000,
         "/Tenant/Prefix/v9///"},
        {"design-default-mp3", "design MP3 default style omits voice", %{}, %{"text" => @text},
         %{"modelId" => "mimo-v2.5-tts-voicedesign", "speakerVoice" => "Mia"},
         "mimo-v2.5-tts-voicedesign", nil, @design_style, "mp3", 30_000, 35_000, "/v1"},
        {"design-style-wav", "design WAV explicit style omits voice", %{}, %{"text" => @text},
         %{
           "model" => "mimo-v2.5-tts-voicedesign",
           "voiceId" => "Milo",
           "format" => "wav",
           "style" => " A bright storyteller. "
         }, "mimo-v2.5-tts-voicedesign", nil, "A bright storyteller.", "wav", 30_000, 35_000,
         "/v1"},
        {"agent-overlay-mp3", "Agent45000 explicit canonical overlays native50000",
         %{
           "timeout_ms" => 45_000,
           "model_id" => " custom-agent-model ",
           "voice_id" => " Agent Custom Voice ",
           "style" => " Agent clear style ",
           "format" => "MP3"
         }, %{"text" => "  " <> @text <> "  ", "channel" => ""},
         %{
           "modelId" => "mimo-v2.5-tts-voicedesign",
           "speakerVoice" => "Mia",
           "style" => "Saved style",
           "format" => "wav",
           "timeoutMs" => 60_000
         }, "custom-agent-model", "Agent Custom Voice", "Agent clear style", "mp3", 45_000,
         50_000, "/custom/prefix///"},
        {"tool-overlay-wav", "tool75000 beats Agent45000 native80000",
         %{
           "timeout_ms" => 45_000,
           "model" => "mimo-v2.5-tts-voicedesign",
           "speaker_voice_id" => "Dean",
           "style" => " Explicit Agent design ",
           "format" => "WAV"
         }, %{"text" => @text, "timeoutMs" => 75_000},
         %{
           "model" => "mimo-v2.5-tts",
           "speakerVoice" => "Chloe",
           "format" => "mp3",
           "style" => "Saved style",
           "timeout_ms" => 60_000
         }, "mimo-v2.5-tts-voicedesign", nil, "Explicit Agent design", "wav", 75_000, 80_000,
         "/v1"}
      ] do
    @provider_fixture %{
      id: id,
      base_path: base_path,
      endpoint_path: String.trim_trailing(base_path, "/") <> "/chat/completions",
      config: Map.put(saved, "max_bytes", 65_536),
      format: format,
      mime: if(format == "mp3", do: "audio/mpeg", else: "audio/wav"),
      audio: if(format == "mp3", do: @mp3, else: @wav),
      timeout: timeout,
      allowance: allowance,
      model: model,
      voice: voice,
      style: style,
      body: %{
        "model" => model,
        "messages" =>
          if(style, do: [%{"role" => "user", "content" => style}], else: []) ++
            [%{"role" => "assistant", "content" => @text}],
        "audio" =>
          if(voice, do: %{"format" => format, "voice" => voice}, else: %{"format" => format})
      }
    }
    @options options
    @input input
    @audio @provider_fixture.audio
    @format format
    @mime @provider_fixture.mime
    test "selected TTS with #{label} settles durable audio and replays success through a new Worker",
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
      assert @name in Profiles.supported_names()
      assert [%{category: :media}] = Enum.filter(DisplayCatalog.list(), &(&1.name == @name))
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
      assert details["provider"] == "xiaomi"
      assert details["outputFormat"] == @format
      assert details["fileExtension"] == "." <> @format
      assert details["voiceCompatible"] == false
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
                 config: %{
                   "model" => "changed-current-model",
                   "voice" => "Changed Current Voice",
                   "style" => "Changed current style",
                   "format" => "wav"
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
                       "model" => "changed-agent-model",
                       "voice" => "Changed Agent Voice",
                       "style" => "Changed Agent style",
                       "format" => "wav"
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

      export_projection(h, use, result, descriptor, delivery)
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
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)

    assert {:ok, credential} =
             Credentials.create(%{
               name: "tts-xiaomi-speech-credential-#{Ecto.UUID.generate()}",
               key: "initial-xiaomi-speech-fixture"
             })

    on_exit(fn -> Credentials.delete(credential.id) end)

    assert {:ok, speech} =
             Providers.create(%{
               name: "tts-xiaomi-speech-#{System.unique_integer([:positive])}",
               type: "xiaomi_speech",
               preset: "xiaomi-speech",
               base_url: Gaoxy.Test.url(fixture, provider_fixture.base_path),
               credential_id: credential.id,
               config: provider_fixture.config
             })

    on_exit(fn -> Providers.delete(speech.id) end)
    assert {:ok, _} = Credentials.update(credential.id, %{key: "current-xiaomi-speech-fixture"})
    assert {:ok, speech} = Providers.get(speech.id)
    media_root = Path.join(root, "durable-audio")
    tts = Map.merge(%{"provider" => speech.name, "media_root" => media_root}, options)
    config = Map.put(h.agent_config.config, "tts", tts)

    assert {:ok, configured_agent} =
             AgentConfigs.update(h.agent_config, %{tools: [@name], config: config})

    assert :ok =
             Synapsis.Provider.Registry.register(h.provider.name, %{
               type: "anthropic",
               base_url: h.provider.base_url,
               api_key: "fixture"
             })

    Agent.update(h.counter, &Map.merge(&1, %{speech: 0, outer: 0}))
    merged_speech = Map.merge(provider_fixture.config, options)

    Map.merge(h, %{
      speech: speech,
      fixture_id: provider_fixture.id,
      configured_agent: configured_agent,
      tts: tts,
      speech_fixture: fixture,
      speech_endpoint: provider_fixture.endpoint_path,
      media_root: media_root,
      synthesis_timeout: provider_fixture.timeout,
      expected_body: provider_fixture.body,
      expected_model: provider_fixture.model,
      expected_voice: provider_fixture.voice,
      expected_style:
        if(provider_fixture.style == @design_style, do: nil, else: provider_fixture.style),
      allowance: provider_fixture.allowance,
      audio: provider_fixture.audio,
      format: provider_fixture.format,
      mime: provider_fixture.mime,
      max_bytes: Map.get(merged_speech, "max_bytes", 16 * 1024 * 1024)
    })
  end

  defp install(h, input) do
    owner = self()

    Gaoxy.Test.stub(h.speech_fixture, "POST", h.speech_endpoint, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params == %{}
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Plug.Conn.get_req_header(conn, "api-key") == ["current-xiaomi-speech-fixture"]
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
      Agent.update(h.counter, &Map.update!(&1, :speech, fn n -> n + 1 end))
      send(owner, {:tts_speech, Jason.decode!(body)})

      response = %{
        "choices" => [%{"message" => %{"audio" => %{"data" => Base.encode64(h.audio)}}}]
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(response))
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

  defp trace_effects do
    calls = [
      {TTS, :execute, 1},
      {Providers, :xiaomi_speech_config, 2},
      {Xiaomi, :synthesize, 2},
      {Xiaomi, :build_request, 2},
      {Synapsis.Provider.Speech.Opus, :transcode, 2},
      {Req, :request, 1},
      {Media, :put_audio, 3},
      {MediaDelivery, :publish, 4}
    ]

    for {module, function, arity} <- calls do
      Code.ensure_loaded!(module)
      spec = if module in [Xiaomi, Providers], do: [{:_, [], [{:return_trace}]}], else: true
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

    assert [{effect, Xiaomi, :synthesize, [request, config]}] =
             Enum.filter(calls, &match?({_, Xiaomi, :synthesize, _}, &1))

    assert [{^effect, TTS, :execute, [operation]}] =
             Enum.filter(calls, &match?({_, TTS, :execute, _}, &1))

    assert is_function(operation.backend_context.effect_deadline, 0)

    prepared =
      for {:returned, _, Providers, :xiaomi_speech_config, {:ok, value}} <- calls, do: value

    assert prepared != []

    for speech <- prepared do
      assert speech.provider_id == h.speech.id
      assert speech.provider_name == h.speech.name
      assert {:ok, _} = Ecto.UUID.cast(speech.provider_id)
    end

    # GenServer return traces originate from the callback actually called in the admitted task.
    deadlines = for {:returned, ^effect, GenServer, :call, {:ok, value}} <- calls, do: value
    assert deadlines != []

    for native <- deadlines do
      assert native.selected_timeout_ms == h.allowance
      assert native.paused == false
      assert native.remaining_ms > 0
      assert native.remaining_ms <= native.selected_timeout_ms
      assert is_integer(native.deadline_ms)
    end

    [native | _] = deadlines
    assert Enum.all?(deadlines, &(&1.deadline_ms == native.deadline_ms))

    assert request.text == @text
    assert request.target == :audio_file
    # Ordinary fast success retains the full synthesis allowance; native time may clip it.
    assert request.timeout_ms == h.synthesis_timeout
    assert request.deadline_ms == native.deadline_ms
    refute Map.has_key?(config, :timeout_ms)
    refute Map.has_key?(config, :timeoutMs)
    assert config[:model] == h.expected_model
    assert config[:format] == h.format
    if h.expected_voice, do: assert(config[:voice] == h.expected_voice)
    assert config[:style] == h.expected_style
    refute Enum.any?(calls, &match?({_, Synapsis.Provider.Speech.Opus, :transcode, _}, &1))
    assert config[:max_bytes] == h.max_bytes
    assert config[:api_key] == "current-xiaomi-speech-fixture"

    assert config[:base_url] == String.trim_trailing(h.speech.base_url, "/")

    built = for {:returned, ^effect, Xiaomi, :build_request, {:ok, value}} <- calls, do: value

    assert Enum.any?(built, fn built ->
             built.body == h.expected_body and
               built.timeout_ms == request.timeout_ms
           end)

    assert [{:returned, ^effect, Xiaomi, :synthesize, {:ok, output}}] =
             Enum.filter(calls, &match?({:returned, ^effect, Xiaomi, :synthesize, _}, &1))

    assert output == %{
             audio: h.audio,
             output_format: h.format,
             file_extension: "." <> h.format,
             voice_compatible: false
           }

    http =
      for {_, Req, :request, [%Req.Request{} = req]} <- calls,
          URI.to_string(req.url) == Gaoxy.Test.url(h.speech_fixture, h.speech_endpoint),
          do: req

    assert [http_request] = http

    for timeout <- [
          http_request.options[:receive_timeout],
          http_request.options[:request_timeout],
          http_request.options[:finch][:pool_timeout]
        ] do
      assert is_integer(timeout) and timeout > 0 and timeout <= request.timeout_ms
    end

    assert [{^effect, Media, :put_audio, [audio, format, opts]}] =
             Enum.filter(calls, &match?({_, Media, :put_audio, _}, &1))

    assert audio == h.audio
    assert format == h.format
    assert opts[:root] == h.media_root
    assert opts[:max_bytes] == config[:max_bytes]
    assert opts[:deadline] == native.deadline_ms

    assert [
             {^effect, MediaDelivery, :publish,
              [^descriptor, session_id, published_operation, delivery_opts]}
           ] =
             Enum.filter(calls, &match?({_, MediaDelivery, :publish, _}, &1))

    assert session_id == h.session.id
    assert delivery_opts[:root] == h.media_root
    assert delivery_opts[:max_bytes] == config[:max_bytes]

    assert fact.invocation ==
             Map.take(published_operation, [:run_id, :invocation_id, :tool_call_id, :tool_name])

    assert {:ok, ^fact} = RuntimeStore.get_fact(session_id, :audio_delivery, delivery["id"])

    assert Enum.find_index(calls, &match?({_, Req, :request, _}, &1)) <
             Enum.find_index(calls, &match?({^effect, Media, :put_audio, _}, &1))

    assert Enum.find_index(calls, &match?({^effect, Media, :put_audio, _}, &1)) <
             Enum.find_index(calls, &match?({^effect, MediaDelivery, :publish, _}, &1))
  end

  defp export_projection(h, use, result, descriptor, delivery) do
    assert {:ok, use_dump} = Synapsis.Part.dump(use)
    assert {:ok, result_dump} = Synapsis.Part.dump(result)

    audio =
      struct(Synapsis.Part.Audio,
        descriptor: descriptor,
        delivery: delivery,
        name: "Xiaomi Speech"
      )

    assert {:ok, audio_dump} = Synapsis.Part.dump(audio)

    if evidence = System.get_env("SYNAPSIS_XIAOMI_EVIDENCE") do
      File.write!(
        Path.join(evidence, "native-#{h.fixture_id}-projection.json"),
        Jason.encode!(
          %{
            rowId: h.fixture_id,
            descriptor: descriptor,
            delivery: delivery,
            audioBase64: Base.encode64(h.audio),
            toolUse: use_dump,
            initial: %{toolResult: result_dump, audioPart: audio_dump},
            history: %{toolResult: result_dump, audioPart: audio_dump}
          },
          pretty: true
        )
      )
    end
  end
end
