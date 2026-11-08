defmodule Synapsis.Session.NativeOpenAISpeechContractFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Agent.MediaDelivery
  alias Synapsis.Agent.Tools.TTS
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.{Speech.OpenAI, ToolName}
  alias Synapsis.Runtime.Store, as: RuntimeStore
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}
  alias Synapsis.Workspace.Media
  alias Synapsis.{AgentConfigs, Credentials, Models, Providers}

  @moduletag :tmp_dir
  @moduletag timeout: 90_000
  @name "synapsis::tts"
  @call_id "ordinary-tts"
  @text "Hello OpenAI & <world>.\n \"Speak\" 'clearly' 🌍"
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

  # Literal ordinary rows cover all four official models and fourteen voices.
  # The local server is a custom transport; choices remain the official literals.
  for {id, model, voice, format, options, input, timeout, allowance, base_path, endpoint_path} <-
        [
          {"default-mp3", "gpt-4o-mini-tts", "coral", "mp3", %{}, %{"text" => @text}, 30_000,
           35_000, "/", "/v1/audio/speech"},
          {"alloy-opus", "gpt-4o-mini-tts-2025-12-15", "alloy", "opus", %{}, %{"text" => @text},
           30_000, 35_000, "/Tenant///", "/Tenant/v1/audio/speech"},
          {"ash-wav", "tts-1", "ash", "wav", %{}, %{"text" => @text}, 30_000, 35_000,
           "/Tenant/v1///", "/Tenant/v1/audio/speech"},
          {"ballad-mp3", "tts-1-hd", "ballad", "mp3", %{}, %{"text" => @text}, 30_000, 35_000,
           "/v1", "/v1/audio/speech"},
          {"cedar-opus", "gpt-4o-mini-tts", "cedar", "opus", %{}, %{"text" => @text}, 30_000,
           35_000, "/v1", "/v1/audio/speech"},
          {"echo-wav", "gpt-4o-mini-tts-2025-12-15", "echo", "wav", %{}, %{"text" => @text},
           30_000, 35_000, "/v1", "/v1/audio/speech"},
          {"fable-mp3", "tts-1", "fable", "mp3", %{}, %{"text" => @text}, 30_000, 35_000, "/v1",
           "/v1/audio/speech"},
          {"juniper-agent50000", "tts-1-hd", "juniper", "opus", %{"timeout_ms" => 45_000},
           %{"text" => @text}, 45_000, 50_000, "/Custom/Prefix///",
           "/Custom/Prefix/v1/audio/speech"},
          {"marin-tool80000", "gpt-4o-mini-tts", "marin", "wav",
           %{
             "timeout_ms" => 45_000,
             "model" => " gpt-4o-mini-tts ",
             "voice" => " marin ",
             "speed" => 1.5,
             "instructions" => " Agent clear cadence. ",
             "response_format" => " WAV "
           }, %{"text" => "  " <> @text <> "  ", "channel" => "", "timeoutMs" => 75_000}, 75_000,
           80_000, "/Custom/Prefix/v1///", "/Custom/Prefix/v1/audio/speech"},
          {"onyx-mp3", "gpt-4o-mini-tts-2025-12-15", "onyx", "mp3", %{}, %{"text" => @text},
           30_000, 35_000, "/v1", "/v1/audio/speech"},
          {"nova-opus", "tts-1", "nova", "opus", %{}, %{"text" => @text}, 30_000, 35_000, "/v1",
           "/v1/audio/speech"},
          {"sage-wav", "tts-1-hd", "sage", "wav", %{}, %{"text" => @text}, 30_000, 35_000, "/v1",
           "/v1/audio/speech"},
          {"shimmer-mp3", "gpt-4o-mini-tts", "shimmer", "mp3", %{}, %{"text" => @text}, 30_000,
           35_000, "/v1", "/v1/audio/speech"},
          {"verse-opus", "gpt-4o-mini-tts-2025-12-15", "verse", "opus", %{}, %{"text" => @text},
           30_000, 35_000, "/v1", "/v1/audio/speech"},
          {"custom-model-voice", "tenant-speech-model", "Tenant Voice", "wav", %{},
           %{"text" => @text}, 30_000, 35_000, "/Custom/Speech///",
           "/Custom/Speech/v1/audio/speech"},
          {"generic-openai", "gpt-4o-mini-tts", "coral", "mp3", %{}, %{"text" => @text}, 30_000,
           35_000, "/", "/v1/audio/speech"},
          {"generic-openai_compat", "tts-1", "alloy", "opus", %{}, %{"text" => @text}, 30_000,
           35_000, "/compat/v1///", "/compat/v1/audio/speech"},
          {"generic-openai_responses", "gpt-4o-mini-tts-2025-12-15", "marin", "wav", %{},
           %{"text" => @text}, 30_000, 35_000, "/responses///", "/responses/v1/audio/speech"},
          {"generic-groq", "tts-1-hd", "verse", "wav", %{}, %{"text" => @text}, 30_000, 35_000,
           "/openai", "/openai/v1/audio/speech"}
        ] do
    generic = String.starts_with?(id, "generic-")
    type = if generic, do: String.replace_prefix(id, "generic-", ""), else: "openai_speech"
    speed = if id == "marin-tool80000", do: 1.5, else: 0.75

    instructions =
      if id == "marin-tool80000", do: "Agent clear cadence.", else: "Saved clear cadence."

    saved = %{
      "model" => " " <> model <> " ",
      "voice" => " " <> voice <> " ",
      "speed" => 0.75,
      "instructions" => " Saved clear cadence. ",
      "responseFormat" => " " <> String.upcase(format) <> " ",
      "extraBody" => %{"fixture_tag" => id, "advanced" => %{"kept" => true}},
      "timeoutMs" => 60_000,
      "timeout_ms" => 90_000,
      "max_bytes" => 65_536
    }

    saved =
      if id == "default-mp3", do: Map.drop(saved, ~w(model voice responseFormat)), else: saved

    saved =
      if id == "marin-tool80000",
        do:
          Map.merge(saved, %{"model" => "tts-1", "voice" => "alloy", "responseFormat" => "opus"}),
        else: saved

    options =
      if generic,
        do:
          Map.merge(
            %{
              "model" => model,
              "voice" => voice,
              "speed" => speed,
              "instructions" => instructions,
              "response_format" => format,
              "max_bytes" => 65_536
            },
            options
          ),
        else: options

    body = %{
      "model" => model,
      "input" => @text,
      "voice" => voice,
      "response_format" => format,
      "speed" => speed,
      "instructions" => instructions
    }

    body = if generic, do: body, else: Map.merge(body, saved["extraBody"])

    @provider_fixture %{
      id: id,
      type: type,
      generic: generic,
      base_path: base_path,
      endpoint_path: endpoint_path,
      config: if(generic, do: %{}, else: saved),
      format: format,
      mime: %{"mp3" => "audio/mpeg", "opus" => "audio/ogg", "wav" => "audio/wav"}[format],
      audio: %{"mp3" => @mp3, "opus" => @opus, "wav" => @wav}[format],
      timeout: timeout,
      allowance: allowance,
      model: model,
      voice: voice,
      speed: speed,
      instructions: instructions,
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
      assert details["provider"] == "openai"
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
                   "model" => "tts-1-hd",
                   "voice" => "shimmer",
                   "responseFormat" => "wav",
                   "speed" => 0.9
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
                       "model" => "tts-1-hd",
                       "voice" => "nova",
                       "response_format" => "wav",
                       "speed" => 1.1
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
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)

    assert {:ok, credential} =
             Credentials.create(%{
               name: "tts-openai-speech-credential-#{Ecto.UUID.generate()}",
               key: "initial-openai-speech-fixture"
             })

    on_exit(fn -> Credentials.delete(credential.id) end)

    assert {:ok, speech} =
             Providers.create(%{
               name: "tts-openai-speech-#{System.unique_integer([:positive])}",
               type: provider_fixture.type,
               base_url: Gaoxy.Test.url(fixture, "/Stale/Root/v1"),
               credential_id: credential.id,
               config: %{
                 "model" => "tts-1",
                 "voice" => "echo",
                 "responseFormat" => "mp3",
                 "max_bytes" => 65_536
               }
             })

    on_exit(fn -> Providers.delete(speech.id) end)

    # Same saved UUID, current connection/settings and referenced credential.
    # Rotate before catalog preparation to preserve ordinary fingerprint admission.
    assert {:ok, _} =
             Providers.update(speech.id, %{
               base_url: Gaoxy.Test.url(fixture, provider_fixture.base_path),
               config: provider_fixture.config
             })

    assert {:ok, _} = Credentials.update(credential.id, %{key: "current-openai-speech-fixture"})
    assert {:ok, speech} = Providers.get(speech.id)
    assert speech.config == provider_fixture.config
    assert speech.api_key_encrypted == "current-openai-speech-fixture"
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
      current_saved_config: provider_fixture.config,
      generic: provider_fixture.generic,
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
      expected_speed: provider_fixture.speed,
      expected_instructions: provider_fixture.instructions,
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
      {Providers, :openai_speech_config, 2},
      {OpenAI, :synthesize, 2},
      {OpenAI, :build_request, 2},
      {OpenAI, :resolve_config, 1},
      {Synapsis.Provider.Speech.Opus, :transcode, 2},
      {Req, :request, 1},
      {Media, :put_audio, 3},
      {MediaDelivery, :publish, 4}
    ]

    for {module, function, arity} <- calls do
      Code.ensure_loaded!(module)
      spec = if module in [OpenAI, Providers], do: [{:_, [], [{:return_trace}]}], else: true
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

    assert [{effect, OpenAI, :synthesize, [request, config]}] =
             Enum.filter(calls, &match?({_, OpenAI, :synthesize, _}, &1))

    assert [{^effect, TTS, :execute, [operation]}] =
             Enum.filter(calls, &match?({_, TTS, :execute, _}, &1))

    assert is_function(operation.backend_context.effect_deadline, 0)
    assert operation.backend_context.provider_id == h.speech.id
    assert operation.backend_context.provider_name == h.speech.name

    prepared =
      for {:returned, _, Providers, :openai_speech_config, {:ok, value}} <- calls, do: value

    if h.generic, do: assert(prepared == []), else: assert(prepared != [])

    for speech <- prepared do
      assert speech.provider_id == h.speech.id
      assert speech.provider_name == h.speech.name
      assert {:ok, _} = Ecto.UUID.cast(speech.provider_id)
    end

    # GenServer return traces originate from the callback actually called in the admitted task.
    assert Enum.any?(
             calls,
             &match?({^effect, GenServer, :call, [_, {:effect_deadline, _}, _]}, &1)
           )

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
    # Preserve raw T and the original Backplane absolute deadline. Actual HTTP
    # timers may clip their remaining wait, but the caller does not replace T.
    assert request.timeout_ms == h.synthesis_timeout
    assert request.deadline_ms == native.deadline_ms
    refute Map.has_key?(config, :timeout_ms)
    refute Map.has_key?(config, :timeoutMs)
    assert config[:model] == h.expected_model
    assert config[:instructions] == h.expected_instructions
    if not h.generic, do: assert(config[:extra_body] == h.current_saved_config["extraBody"])
    assert Enum.any?(calls, &match?({_, OpenAI, :resolve_config, _}, &1))

    assert config[:response_format] ==
             if(h.fixture_id == "default-mp3", do: nil, else: h.format)

    if h.expected_voice, do: assert(config[:voice] == h.expected_voice)
    assert config[:speed] == h.expected_speed
    refute Enum.any?(calls, &match?({_, Synapsis.Provider.Speech.Opus, :transcode, _}, &1))
    assert config[:max_bytes] == h.max_bytes
    assert config[:api_key] == "current-openai-speech-fixture"

    assert config[:base_url] <> "/audio/speech" ==
             Gaoxy.Test.url(h.speech_fixture, h.speech_endpoint)

    built = for {:returned, ^effect, OpenAI, :build_request, {:ok, value}} <- calls, do: value

    assert Enum.any?(built, fn built ->
             built.body == h.expected_body and
               built.timeout_ms == request.timeout_ms and
               built[:deadline_ms] == native.deadline_ms
           end)

    assert [{:returned, ^effect, OpenAI, :synthesize, {:ok, output}}] =
             Enum.filter(calls, &match?({:returned, ^effect, OpenAI, :synthesize, _}, &1))

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
          name: "OpenAI"
        )

      assert {:ok, dump} = Synapsis.Part.dump(audio)

      assert {:ok, ^audio} =
               dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()

      dump
    end

    if evidence = System.get_env("OPENAI342_NATIVE_EXPORT") do
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
