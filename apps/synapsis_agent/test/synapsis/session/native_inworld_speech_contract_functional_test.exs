defmodule Synapsis.Session.NativeInworldSpeechContractFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Agent.MediaDelivery
  alias Synapsis.Agent.Tools.TTS
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.{Speech.Inworld, ToolName}
  alias Synapsis.Runtime.Store, as: RuntimeStore
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}
  alias Synapsis.Workspace.Media
  alias Synapsis.{AgentConfigs, Credentials, Models, Providers}

  @moduletag timeout: 90_000
  @name "synapsis::tts"
  @call_id "ordinary-tts"
  @text "Ordinary speech.\n \"Speak\" 'clearly' 🌍"
  @spoken "(spoken) " <> @text
  # Immutable valid local MP3 bytes qualify media publication; source opaque
  # transport vectors remain in the independent provider contract tests.
  @mp3 Base.decode64!(
         "SUQzBAAAAAAAI1RTU0UAAAAPAAADTGF2ZjYyLjEyLjEwMgAAAAAAAAAAAAAA//OEwAAAAAAAAAAAAEluZm8AAAAPAAAABwAAA2AAVVVVVVVVVVVVVVVVVVVxcXFxcXFxcXFxcXFxcY6Ojo6Ojo6Ojo6Ojo6Oqqqqqqqqqqqqqqqqqqqqx8fHx8fHx8fHx8fHx8fj4+Pj4+Pj4+Pj4+Pj4///////////////////AAAAAExhdmM2Mi4yOAAAAAAAAAAAAAAAACQEIAAAAAAAAANgrF8r0wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA//NExAARgE6kX08YAAHv+2/AQ9D0PQ80zrVa4IIBnAzgqwkYm5L1Gzx4gIAgCAYicPvygYy4P8EHTnBN+J3cv7un3dPuxAAwfw+CByoBh/gh0+4gCSDCCAQAAI3Fnt1N//NExA0ViT6c15tQAFCYaqHeFgwXnkgwJLDxC0ycOLbPb18+ASgMgK/iCBuBuFX/ESIkiHw+/8hHo9Ih8Pv/yEej04fD43+CoiCoK/8sFQVEQVBX/8sqLnJXLrMAaAMz//NExAkUyFosAd8AAACIATMAyAITArwbQwZwSAMDUB9zBbwoo3GVFuMjOCgTBlwaAwOEDSMDvAfDAJAEcwCAAhMAgABwSAFF8l/S3////////9X////01YmsIXDMIKMy//NExAgS+F4cANf4JJTgYDArwUcxG0bNMFiALzBRxH06GTP3MXrCbzmjOM+mEx4MjD4bMIA4wSBy5adD92P1/+5enR9n/q/+32/+n5PT72ccYAtt2//wAGff1SOhOO4+//NExA8WOba1v1owAooOZukX8ZJSbzz+A37l+denp6e2hGPd3dxGPd69kEMe7/sghl3rYeACGXetlkCGXfbLIIZd+Msghj34xyCGPvjHIBgmUcGOUdwxjAAAFotFotFA//NExAkUAT7aX5OIAqBAAAAARVBGomijjUC6KuMQr+FUCKBbMckqFni3icBO5EzFA6j44BmyfIgRdlo1/L5OEXMy4X16/9MuF9aBmv+CYkC4jb/qTEFNRTMuMTAwVVVV//NExAwAAANIAcAAAFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV"
       )
  # Host consumer fixtures independently composed from the pinned source contract.
  # Inworld publishes MP3 only; note and phone remain service-only.
  setup_all do
    partition = System.fetch_env!("MIX_TEST_PARTITION")
    base = Path.expand("../../../../../tmp/inworld346_native" <> partition, __DIR__)
    :ok = File.mkdir(base)
    {:ok, native_base: base}
  end

  setup %{native_base: base} do
    root = Path.join(base, Ecto.UUID.generate())
    :ok = File.mkdir(root)
    {:ok, tmp_dir: root}
  end

  for {id, saved, options, input, model, voice, temperature, timeout, base_path} <- [
        {"default", %{}, %{}, %{"text" => @text}, "inworld-tts-1.5-max", "Sarah", nil, 30_000,
         "/"},
        {"saved-aliases",
         %{"modelId" => " inworld-tts-1-max ", "voiceId" => " Dennis ", "temperature" => 0.8},
         %{}, %{"text" => @text}, "inworld-tts-1-max", "Dennis", 0.8, 30_000,
         "/Tenant/Speech///"},
        {"partial-agent",
         %{"modelId" => " inworld-tts-1.5-mini ", "voiceId" => "Dennis", "temperature" => 0.8},
         %{"voice_id" => " Ashley ", "timeout_ms" => 45_000}, %{"text" => @text},
         "inworld-tts-1.5-mini", "Ashley", 0.8, 45_000, "/Current/Agent///"},
        {"tool-timeout",
         %{"model_id" => "inworld-tts-1", "voice_id" => "Olivia", "temperature" => 0.9},
         %{"temperature" => 1.2, "timeout_ms" => 45_000, "max_bytes" => 131_072},
         %{"text" => "  " <> @text <> "  ", "channel" => "", "timeoutMs" => 75_000},
         "inworld-tts-1", "Olivia", 1.2, 75_000, "/Current/Tool///"},
        {"custom",
         %{"modelId" => " __custom__ ", "voiceId" => " CustomInworldVoice ", "temperature" => 1},
         %{}, %{"text" => @text}, "__custom__", "CustomInworldVoice", 1, 30_000,
         "/Custom/Speech///"}
      ] do
    saved =
      Map.merge(
        %{
          "timeout_ms" => 90_000,
          "timeoutMs" => 60_000,
          "max_bytes" => 65_536,
          "base_url" => "https://saved-shadow.example.test/never-selected",
          "advanced_fixture" => %{"labels" => ["preserve", "all"]}
        },
        saved
      )

    body = %{
      "text" => @text,
      "voiceId" => voice,
      "modelId" => model,
      "audioConfig" => %{"audioEncoding" => "MP3"}
    }

    body = if is_nil(temperature), do: body, else: Map.put(body, "temperature", temperature)

    @provider_fixture %{
      id: id,
      base_path: base_path,
      endpoint_path: String.trim_trailing(base_path, "/") <> "/tts/v1/voice:stream",
      config: saved,
      timeout: timeout,
      allowance: timeout + 5_000,
      model: model,
      voice: voice,
      temperature: temperature,
      body: body
    }
    @options options
    @input input
    test "selected TTS with #{id} settles durable audio and replays success through a new Worker",
         %{tmp_dir: root} do
      h = harness(root, @options, @provider_fixture)
      audio = @mp3
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

      assert_receive {:tts_speech, request, response_owner}, 10_000
      assert request == @provider_fixture.body
      observe_native_http_join(response_owner, h.speech_endpoint)

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
      assert details["provider"] == "inworld"
      assert Map.get(details, "timeoutMs") == @input["timeoutMs"]
      assert Map.has_key?(details, "timeoutMs") == Map.has_key?(@input, "timeoutMs")
      descriptor = details["mediaDescriptor"]
      uri = descriptor["uri"]
      sha256 = Base.encode16(:crypto.hash(:sha256, audio), case: :lower)
      assert uri == "synapsis-media://audio/" <> sha256 <> ".mp3"

      assert descriptor == %{
               "uri" => uri,
               "sha256" => sha256,
               "byte_size" => byte_size(audio),
               "mime_type" => "audio/mpeg",
               "format" => "mp3"
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

      assert [audio_path] = Path.wildcard(Path.join(h.media_root, "**/*.mp3"))
      audio_stat = File.stat!(audio_path, time: :posix)
      assert File.read!(audio_path) == audio
      assert following["tools"] == initial["tools"]
      assert_text_wire(following, @input)
      assert_round_trip_and_store(h.session.id, [use, result], root, audio)
      aggregate = assert_runtime_aggregate(locator, native)

      assert {:ok, _} =
               Providers.update(h.speech.id, %{
                 base_url: Gaoxy.Test.url(h.speech_fixture, "/Changed/After/Completion"),
                 config: %{
                   "modelId" => "inworld-tts-1",
                   "voiceId" => "LaterInworldVoice",
                   "temperature" => 0.9
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
                       "model_id" => "inworld-tts-1",
                       "voice_id" => "LaterAgentVoice",
                       "temperature" => 1.1
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
    # Even a preimplementation wrong-root RED stays on this local HTTP fixture.
    provider_fixture =
      put_in(
        provider_fixture.config["base_url"],
        Gaoxy.Test.url(fixture, "/Saved/Shadow/Not/Connection")
      )

    assert {:ok, credential} =
             Credentials.create(%{
               name: "tts-inworld-credential-#{Ecto.UUID.generate()}",
               key: "initial-inworld-speech-fixture"
             })

    on_exit(fn -> Credentials.delete(credential.id) end)

    assert {:ok, replacement} =
             Credentials.create(%{
               name: "tts-inworld-current-#{Ecto.UUID.generate()}",
               key: "replacement-inworld-speech-fixture"
             })

    on_exit(fn -> Credentials.delete(replacement.id) end)

    assert {:ok, speech} =
             Providers.create(%{
               name: "tts-inworld-speech-#{Ecto.UUID.generate()}",
               type: "inworld_speech",
               preset: "inworld-speech",
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
               %{key: "current-inworld-speech-fixture"}
             )

    assert {:ok, speech} = Providers.get(speech.id)
    assert speech.credential_id == replacement.id
    assert speech.config == provider_fixture.config
    assert speech.api_key_encrypted == "current-inworld-speech-fixture"
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
      media_root: media_root,
      synthesis_timeout: provider_fixture.timeout,
      expected_body: provider_fixture.body,
      expected_model: provider_fixture.model,
      expected_voice: provider_fixture.voice,
      expected_temperature: provider_fixture.temperature,
      allowance: provider_fixture.allowance,
      audio: @mp3,
      format: "mp3",
      mime: "audio/mpeg",
      max_bytes: Map.get(options, "max_bytes", provider_fixture.config["max_bytes"])
    })
  end

  defp install(h, input) do
    owner = self()

    Gaoxy.Test.stub(h.speech_fixture, "POST", h.speech_endpoint, fn conn ->
      assert conn.query_string == ""

      assert Plug.Conn.get_req_header(conn, "authorization") == [
               "Basic current-inworld-speech-fixture"
             ]

      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      Agent.update(h.counter, &Map.update!(&1, :speech, fn n -> n + 1 end))
      send(owner, {:tts_speech, Jason.decode!(body), self()})

      # Ordinary successful response held only to attach receive observation to
      # the original effect owner, before it awaits its actual HTTP task DOWN.
      receive do
        :return_inworld_audio ->
          <<first::binary-size(31), rest::binary>> = h.audio

          ndjson =
            "\n" <>
              Jason.encode!(%{"result" => %{"audioContent" => Base.encode64(first)}}) <>
              "\n" <>
              Jason.encode!(%{"requestId" => "ordinary-native-speech"}) <>
              "\n\n" <>
              Jason.encode!(%{"result" => %{"audioContent" => Base.encode64(rest)}}) <> "\n"

          conn
          |> Plug.Conn.put_resp_content_type("application/x-ndjson")
          |> Plug.Conn.resp(200, ndjson)
      after
        10_000 -> raise "ordinary Inworld audio response was not released"
      end
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
      {Providers, :inworld_speech_config, 2},
      {Inworld, :synthesize, 2},
      {Inworld, :build_request, 2},
      {Inworld, :resolve_config, 1},
      {Task, :async, 1},
      {Req, :request, 1},
      {Media, :put_audio, 3},
      {MediaDelivery, :publish, 4}
    ]

    for {module, function, arity} <- calls do
      Code.ensure_loaded!(module)

      spec =
        if module in [Inworld, Providers, Task], do: [{:_, [], [{:return_trace}]}], else: true

      :erlang.trace_pattern({module, function, arity}, spec, [:local])
    end

    :erlang.trace_pattern(
      {GenServer, :call, 3},
      [{[:_, {:effect_deadline, :_}, :_], [], [{:return_trace}]}],
      [:local]
    )

    :erlang.trace(:all, true, [:call, {:tracer, self()}])

    on_exit(fn ->
      :erlang.trace(:all, false, [:call, :receive])
      for mfa <- calls ++ [{GenServer, :call, 3}], do: :erlang.trace_pattern(mfa, false, [:local])
    end)
  end

  defp observe_native_http_join(response_owner, endpoint) do
    assert_receive {:trace, effect, :call, {TTS, :execute, [operation]}}, 5_000

    assert_receive {:trace, http, :call,
                    {Req, :request, [%Req.Request{url: %URI{path: ^endpoint}} = request]}},
                   5_000

    assert {:links, links} = Process.info(http, :links)
    assert effect in links
    assert :erlang.trace(effect, true, [:receive]) == 1

    Process.put(:inworld_early_calls, [
      {effect, TTS, :execute, [operation]},
      {http, Req, :request, [request]}
    ])

    send(response_owner, :return_inworld_audio)
  end

  defp traced_calls do
    barrier = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^barrier}, 5_000
    Process.get(:inworld_early_calls, []) ++ drain_calls([])
  end

  defp drain_calls(calls) do
    receive do
      {:trace, pid, :call, {module, function, arguments}} ->
        drain_calls([{pid, module, function, arguments} | calls])

      {:trace, pid, :return_from, {module, function, _arity}, result} ->
        drain_calls([{:returned, pid, module, function, result} | calls])

      {:trace, pid, :receive, {:DOWN, _monitor, :process, _task, _reason} = message} ->
        drain_calls([{:received, pid, message} | calls])

      {:trace, _pid, :receive, _message} ->
        drain_calls(calls)
    after
      0 -> Enum.reverse(calls)
    end
  end

  defp assert_once_each_effect(h, _input, descriptor, delivery, fact) do
    calls = traced_calls()

    assert [{effect, Inworld, :synthesize, [request, config]}] =
             Enum.filter(calls, &match?({_, Inworld, :synthesize, _}, &1))

    assert [{^effect, TTS, :execute, [operation]}] =
             Enum.filter(calls, &match?({_, TTS, :execute, _}, &1))

    assert is_function(operation.backend_context.effect_deadline, 0)
    assert operation.backend_context.provider_id == h.speech.id
    assert operation.backend_context.provider_name == h.speech.name

    prepared =
      for {:returned, _, Providers, :inworld_speech_config, {:ok, value}} <- calls,
          do: value

    assert prepared != []

    for speech <- prepared do
      assert speech.provider_id == h.speech.id
      assert speech.provider_name == h.speech.name
      assert speech.timeout_ms == Map.get(h.tts, "timeout_ms", 30_000)
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
    assert config.model_id == h.expected_model
    assert config.voice_id == h.expected_voice
    assert config[:temperature] == h.expected_temperature
    assert config.max_bytes == h.max_bytes
    assert config.api_key == "current-inworld-speech-fixture"
    assert config.base_url == h.expected_root

    built = for {:returned, ^effect, Inworld, :build_request, {:ok, value}} <- calls, do: value

    assert Enum.any?(built, fn built ->
             built.body == h.expected_body and built.timeout_ms == h.synthesis_timeout and
               built[:deadline_ms] == native.deadline_ms and
               is_integer(built[:transport_deadline_ms]) and
               built.transport_deadline_ms <= native.deadline_ms and
               URI.parse(built.url).path == h.speech_endpoint
           end)

    assert [{:returned, ^effect, Inworld, :synthesize, {:ok, output}}] =
             Enum.filter(calls, &match?({:returned, ^effect, Inworld, :synthesize, _}, &1))

    assert output == %{
             audio: h.audio,
             output_format: "mp3",
             file_extension: ".mp3",
             voice_compatible: false
           }

    http =
      for {pid, Req, :request, [%Req.Request{} = req]} <- calls,
          req.url.path == h.speech_endpoint,
          do: {pid, req}

    assert [{http_pid, http_request}] = http

    tasks = for {:returned, ^effect, Task, :async, %Task{} = task} <- calls, do: task
    assert [task] = tasks
    assert task.pid == http_pid
    refute Process.alive?(http_pid)

    for timeout <- [
          http_request.options[:receive_timeout],
          http_request.options[:request_timeout],
          http_request.options[:finch][:pool_timeout]
        ] do
      assert is_integer(timeout) and timeout > 0 and timeout <= h.synthesis_timeout
    end

    assert http_request.options[:receive_timeout] <= 30_000

    audio = h.audio

    assert [{^effect, Media, :put_audio, [^audio, "mp3", opts]}] =
             Enum.filter(calls, &match?({_, Media, :put_audio, _}, &1))

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
             Map.take(published_operation, [:run_id, :invocation_id, :tool_call_id, :tool_name])

    assert {:ok, ^fact} = RuntimeStore.get_fact(session_id, :audio_delivery, delivery["id"])

    # These observations come from the same original effect PID. Its actual
    # linked HTTP task DOWN must arrive before that effect publishes audio.
    down =
      Enum.find_index(calls, fn
        {:received, ^effect, {:DOWN, _monitor, :process, ^http_pid, reason}} ->
          reason in [:normal, :noproc]

        _ ->
          false
      end)

    media = Enum.find_index(calls, &match?({^effect, Media, :put_audio, _}, &1))
    publication = Enum.find_index(calls, &match?({^effect, MediaDelivery, :publish, _}, &1))
    assert is_integer(down)
    assert down < media
    assert media < publication
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

    audio_part = fn part ->
      details = part.projection["result"]["details"]

      audio =
        struct(Synapsis.Part.Audio,
          descriptor: details["mediaDescriptor"],
          delivery: details["mediaDelivery"],
          name: "Inworld"
        )

      assert {:ok, dump} = Synapsis.Part.dump(audio)
      assert {:ok, ^audio} = dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
      dump
    end

    evidence = System.get_env("INWORLD346_NATIVE_EXPORT")

    if evidence && h.fixture_id == "default" do
      File.write!(
        Path.join(evidence, "native-default-projection.json"),
        Jason.encode!(
          %{
            rowId: h.fixture_id,
            format: "mp3",
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
        ),
        [:exclusive]
      )
    end
  end
end
