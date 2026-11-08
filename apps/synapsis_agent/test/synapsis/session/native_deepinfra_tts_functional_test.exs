defmodule Synapsis.Session.NativeDeepInfraTTSFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Agent.MediaDelivery
  alias Synapsis.Agent.Tools.{DisplayCatalog, Profiles, TTS}
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.{Speech.DeepInfra, ToolName}
  alias Synapsis.Runtime.Store, as: RuntimeStore
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}
  alias Synapsis.Workspace.Media
  alias Synapsis.{AgentConfigs, Credentials, Models, Providers}

  @moduletag :tmp_dir
  @moduletag timeout: 90_000
  @name "synapsis::tts"
  @call_id "ordinary-tts"
  @text "Hello from the ordinary speech fixture."
  @spoken "(spoken) " <> @text
  # These fixture bytes are deliberately opaque; no codec or playback claim.
  @mp3 <<255, 251, 144, "ordinary opaque MP3", 0, 7>>
  @opus <<"OggS", 0, 255, "ordinary opaque Opus", 9>>
  @flac <<"fLaC", 0, 128, "ordinary opaque FLAC", 254>>
  @wav <<"RIFF", 0, 255, "ordinary opaque WAV", 8>>
  @pcm <<0, 255, 128, "ordinary opaque PCM", 0, 254, 9>>

  # Literal source-grounded requests, independent of the host implementation.
  # Every row exercises the same full native lifecycle and distinct Worker replay.
  for {label, options, input, fixture} <- [
        {"MP3 absent timeout uses provider 120000 and native 125000", %{}, %{"text" => @text},
         %{
           base_path: "/v1/openai",
           endpoint_path: "/v1/openai/audio/speech",
           config: %{},
           format: "mp3",
           mime: "audio/mpeg",
           audio: @mp3,
           timeout: 120_000,
           body: %{
             "model" => "hexgrad/Kokoro-82M",
             "input" => @text,
             "voice" => "af_bella",
             "response_format" => "mp3"
           }
         }},
        {"Opus Agent 45000 uses native 50000 and saved source aliases", %{"timeout_ms" => 45_000},
         %{"text" => @text},
         %{
           base_path: "/ordinary/deepinfra/v7///",
           endpoint_path: "/ordinary/deepinfra/v7/audio/speech",
           config: %{
             "modelId" => " deepinfra/Qwen/Qwen3-TTS ",
             "speakerVoice" => " saved-qwen-voice ",
             "voice" => "unused-lower-voice",
             "responseFormat" => " OPUS ",
             "speed" => 0,
             "extraBody" => %{"temperature" => 0.65, "options" => %{"seed" => 7}}
           },
           format: "opus",
           mime: "audio/ogg",
           audio: @opus,
           timeout: 45_000,
           body: %{
             "model" => "Qwen/Qwen3-TTS",
             "input" => @text,
             "voice" => "saved-qwen-voice",
             "response_format" => "opus",
             "speed" => 0,
             "extra_body" => %{"temperature" => 0.65, "options" => %{"seed" => 7}}
           }
         }},
        {"FLAC explicit Agent 30000 uses native 35000 and overrides normalized saved settings",
         %{
           "timeout_ms" => 30_000,
           "model" => " deepinfra/custom/agent-model ",
           "voice" => " agent-voice ",
           "speed" => 1.4,
           "response_format" => "flac"
         }, %{"text" => "  " <> @text <> "  ", "channel" => ""},
         %{
           base_path: "/custom/deepinfra/v8///",
           endpoint_path: "/custom/deepinfra/v8/audio/speech",
           config: %{
             "modelId" => "deepinfra/ResembleAI/chatterbox-turbo",
             "speakerVoice" => " saved-speaker ",
             "voiceId" => "saved-secondary",
             "speed" => 1.15,
             "responseFormat" => "mp3",
             "extraBody" => %{
               "model" => "nested-model",
               "input" => "nested-input",
               "response_format" => "nested-format",
               "options" => %{"seeds" => [7, 11], "style" => "中文"}
             }
           },
           format: "flac",
           mime: "audio/flac",
           audio: @flac,
           timeout: 30_000,
           body: %{
             "model" => "custom/agent-model",
             "input" => @text,
             "voice" => "agent-voice",
             "response_format" => "flac",
             "speed" => 1.4,
             "extra_body" => %{
               "model" => "nested-model",
               "input" => "nested-input",
               "response_format" => "nested-format",
               "options" => %{"seeds" => [7, 11], "style" => "中文"}
             }
           }
         }},
        {"WAV tool 75000 supersedes Agent 45000 and uses native 80000", %{"timeout_ms" => 45_000},
         %{"text" => @text, "timeoutMs" => 75_000},
         %{
           base_path: "/v1/openai",
           endpoint_path: "/v1/openai/audio/speech",
           config: %{
             "model" => "deepinfra/deepinfra/deepinfra/Qwen/Qwen3-TTS",
             "voiceId" => "ordinary-wav-voice",
             "responseFormat" => " WAV ",
             "speed" => 1.2
           },
           format: "wav",
           mime: "audio/wav",
           audio: @wav,
           timeout: 75_000,
           body: %{
             "model" => "Qwen/Qwen3-TTS",
             "input" => @text,
             "voice" => "ordinary-wav-voice",
             "response_format" => "wav",
             "speed" => 1.2
           }
         }},
        {"PCM saved format retains provider 120000 and native 125000", %{}, %{"text" => @text},
         %{
           base_path: "/custom/deepinfra/speech",
           endpoint_path: "/custom/deepinfra/speech/audio/speech",
           config: %{
             "modelId" => "deepinfra/sesame/csm-1b",
             "voiceId" => "ordinary-pcm-voice",
             "responseFormat" => " PCM ",
             "extraBody" => %{"ordinary" => true}
           },
           format: "pcm",
           mime: "application/octet-stream",
           audio: @pcm,
           timeout: 120_000,
           body: %{
             "model" => "sesame/csm-1b",
             "input" => @text,
             "voice" => "ordinary-pcm-voice",
             "response_format" => "pcm",
             "extra_body" => %{"ordinary" => true}
           }
         }}
      ] do
    @options options
    @input input
    @provider_fixture fixture
    @audio fixture.audio
    @format fixture.format
    @mime fixture.mime
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
      assert schema["properties"]["timeoutMs"]["minimum"] == 1
      refute Map.has_key?(schema["properties"]["timeoutMs"], "maximum")
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
      assert details["provider"] == "deepinfra"
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
               AgentConfigs.update(h.configured_agent, %{
                 config:
                   Map.put(
                     h.configured_agent.config,
                     "tts",
                     Map.merge(h.tts, %{
                       "media_root" => Path.join(root, "new-audio-root"),
                       "max_bytes" => 8_192
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
               name: "tts-deepinfra-credential-#{Ecto.UUID.generate()}",
               key: "initial-deepinfra-fixture"
             })

    on_exit(fn -> Credentials.delete(credential.id) end)

    assert {:ok, speech} =
             Providers.create(%{
               name: "tts-deepinfra-#{System.unique_integer([:positive])}",
               type: "deepinfra_speech",
               preset: "deepinfra-speech",
               base_url: Gaoxy.Test.url(fixture, provider_fixture.base_path),
               credential_id: credential.id,
               config: provider_fixture.config
             })

    on_exit(fn -> Providers.delete(speech.id) end)
    assert {:ok, _} = Credentials.update(credential.id, %{key: "current-deepinfra-fixture"})
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
      configured_agent: configured_agent,
      tts: tts,
      speech_fixture: fixture,
      speech_endpoint: provider_fixture.endpoint_path,
      media_root: media_root,
      synthesis_timeout: provider_fixture.timeout,
      expected_body: provider_fixture.body,
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
      conn |> Plug.Conn.put_resp_content_type(h.mime) |> Plug.Conn.resp(200, h.audio)
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
      {DeepInfra, :synthesize, 2},
      {DeepInfra, :build_request, 2},
      {Req, :request, 1},
      {Media, :put_audio, 3},
      {MediaDelivery, :publish, 4}
    ]

    for {module, function, arity} <- calls do
      Code.ensure_loaded!(module)
      spec = if module == DeepInfra, do: [{:_, [], [{:return_trace}]}], else: true
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

    assert [{effect, DeepInfra, :synthesize, [request, config]}] =
             Enum.filter(calls, &match?({_, DeepInfra, :synthesize, _}, &1))

    assert [{^effect, TTS, :execute, [operation]}] =
             Enum.filter(calls, &match?({_, TTS, :execute, _}, &1))

    assert is_function(operation.backend_context.effect_deadline, 0)
    # GenServer return traces originate from the callback actually called in the admitted task.
    deadlines = for {:returned, ^effect, GenServer, :call, {:ok, value}} <- calls, do: value
    assert deadlines != []

    for native <- deadlines do
      assert native.selected_timeout_ms == h.synthesis_timeout + 5_000
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
    assert request.timeout_ms <= h.synthesis_timeout
    assert request.timeout_ms > h.synthesis_timeout - 5_000
    assert config[:max_bytes] == h.max_bytes
    assert config[:api_key] == "current-deepinfra-fixture"

    assert String.trim_trailing(config[:base_url], "/") ==
             String.trim_trailing(h.speech.base_url, "/")

    built = for {:returned, ^effect, DeepInfra, :build_request, {:ok, value}} <- calls, do: value
    assert Enum.any?(built, &(&1.body == h.expected_body and &1.timeout_ms == request.timeout_ms))

    assert [{:returned, ^effect, DeepInfra, :synthesize, {:ok, output}}] =
             Enum.filter(calls, &match?({:returned, ^effect, DeepInfra, :synthesize, _}, &1))

    assert output == %{
             audio: h.audio,
             output_format: h.format,
             file_extension: "." <> h.format,
             voice_compatible: h.format in ["mp3", "opus"]
           }

    http =
      for {_, Req, :request, [%Req.Request{} = req]} <- calls,
          URI.to_string(req.url) ==
            String.trim_trailing(h.speech.base_url, "/") <> "/audio/speech",
          do: req

    assert [http_request] = http
    assert http_request.options[:receive_timeout] == request.timeout_ms
    assert http_request.options[:request_timeout] == request.timeout_ms
    assert http_request.options[:finch][:pool_timeout] == request.timeout_ms

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
  end
end
