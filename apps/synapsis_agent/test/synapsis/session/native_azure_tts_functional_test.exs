defmodule Synapsis.Session.NativeAzureTTSFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Agent.MediaDelivery
  alias Synapsis.Agent.Tools.{DisplayCatalog, Profiles, TTS}
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.{Speech.Azure, ToolName}
  alias Synapsis.Runtime.Store, as: RuntimeStore
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}
  alias Synapsis.Workspace.Media
  alias Synapsis.{AgentConfigs, Credentials, Models, Providers}

  @moduletag :tmp_dir
  @moduletag timeout: 90_000
  @name "synapsis::tts"
  @call_id "ordinary-tts"
  @text "Hello Azure & <world>.\n \"Speak\" 'clearly' 🌍"
  @spoken "(spoken) " <> @text
  # Source-qualified opaque response bytes; this test does not claim codec decoding.
  @audio <<0, 1, 2, 254, 255>>
  @ssml "<speak version=\"1.0\" xmlns=\"http://www.w3.org/2001/10/synthesis\" xml:lang=\"en-US\"><voice name=\"en-US-JennyNeural\">Hello Azure &amp; &lt;world&gt;.\n \"Speak\" 'clearly' 🌍</voice></speak>"

  # Expectations are literal Azure source/design values, independent of host implementation.
  for {label, options, input, config, vendor_format, format, mime, compatible, timeout,
       source_timeout, allowance} <- [
        {"default MP3 native35000", %{}, %{"text" => @text}, %{},
         "audio-24khz-48kbitrate-mono-mp3", "mp3", "audio/mpeg", false, 30_000, nil, 35_000},
        {"configured Ogg retains .ogg", %{}, %{"text" => @text},
         %{"outputFormat" => "OGG-24KHZ-16BIT-MONO-OPUS"}, "OGG-24KHZ-16BIT-MONO-OPUS", "ogg",
         "audio/ogg", true, 30_000, nil, 35_000},
        {"configured WebM", %{}, %{"text" => @text},
         %{"output_format" => "webm-24khz-16bit-mono-opus"}, "webm-24khz-16bit-mono-opus", "webm",
         "audio/webm", false, 30_000, nil, 35_000},
        {"configured WAV", %{}, %{"text" => @text},
         %{"outputFormat" => "riff-24khz-16bit-mono-pcm"}, "riff-24khz-16bit-mono-pcm", "wav",
         "audio/wav", false, 30_000, nil, 35_000},
        {"configured raw PCM", %{}, %{"text" => @text},
         %{"output_format" => "raw-24khz-16bit-mono-pcm"}, "raw-24khz-16bit-mono-pcm", "pcm",
         "application/octet-stream", false, 30_000, nil, 35_000},
        {"configured AMR", %{}, %{"text" => @text}, %{"outputFormat" => "amr-wb-16000hz"},
         "amr-wb-16000hz", "amr", "audio/amr", false, 30_000, nil, 35_000},
        {"configured opaque audio", %{}, %{"text" => @text},
         %{"outputFormat" => "vendor-custom-audio"}, "vendor-custom-audio", "audio",
         "application/octet-stream", false, 30_000, nil, 35_000},
        {"saved60000 beats tool75000 native65000", %{}, %{"text" => @text, "timeoutMs" => 75_000},
         %{"timeoutMs" => 60_000}, "audio-24khz-48kbitrate-mono-mp3", "mp3", "audio/mpeg", false,
         60_000, 60_000, 65_000},
        {"Agent45000 beats saved60000 and tool75000 native50000", %{"timeout_ms" => 45_000},
         %{"text" => @text, "timeoutMs" => 75_000}, %{"timeout_ms" => 60_000},
         "audio-24khz-48kbitrate-mono-mp3", "mp3", "audio/mpeg", false, 45_000, 45_000, 50_000},
        {"tool75000 fallback native80000", %{}, %{"text" => @text, "timeoutMs" => 75_000}, %{},
         "audio-24khz-48kbitrate-mono-mp3", "mp3", "audio/mpeg", false, 75_000, nil, 80_000},
        {"fractional configured12345.5 native17346", %{}, %{"text" => @text},
         %{"timeoutMs" => 12_345.5}, "audio-24khz-48kbitrate-mono-mp3", "mp3", "audio/mpeg",
         false, 12_346, 12_345.5, 17_346}
      ] do
    @provider_fixture %{
      base_path: "/tenant/CognitiveServices/V1///",
      endpoint_path: "/tenant/cognitiveservices/v1",
      config: config,
      format: format,
      mime: mime,
      audio: @audio,
      timeout: timeout,
      source_timeout: source_timeout,
      allowance: allowance,
      vendor_format: vendor_format,
      voice_compatible: compatible,
      body: @ssml
    }
    @options options
    @input input
    @format format
    @mime mime
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
      assert details["provider"] == "azure"
      assert details["outputFormat"] == @provider_fixture.vendor_format
      assert details["fileExtension"] == "." <> @format
      assert details["voiceCompatible"] == @provider_fixture.voice_compatible
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
                   "voice" => "fr-FR-DeniseNeural",
                   "outputFormat" => "riff-16khz-16bit-mono-pcm"
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

      if @provider_fixture.source_timeout == nil and not Map.has_key?(@input, "timeoutMs") do
        export_projection(h, use, result, descriptor, delivery)
      end
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
               name: "tts-azure-speech-credential-#{Ecto.UUID.generate()}",
               key: "initial-azure-speech-fixture"
             })

    on_exit(fn -> Credentials.delete(credential.id) end)

    assert {:ok, speech} =
             Providers.create(%{
               name: "tts-azure-speech-#{System.unique_integer([:positive])}",
               type: "azure_speech",
               preset: "azure-speech",
               base_url: Gaoxy.Test.url(fixture, provider_fixture.base_path),
               credential_id: credential.id,
               config: provider_fixture.config
             })

    on_exit(fn -> Providers.delete(speech.id) end)
    assert {:ok, _} = Credentials.update(credential.id, %{key: "current-azure-speech-fixture"})
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
      vendor_format: provider_fixture.vendor_format,
      voice_compatible: provider_fixture.voice_compatible,
      source_timeout: provider_fixture.source_timeout,
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

      assert Plug.Conn.get_req_header(conn, "ocp-apim-subscription-key") ==
               ["current-azure-speech-fixture"]

      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/ssml+xml"]
      assert Plug.Conn.get_req_header(conn, "x-microsoft-outputformat") == [h.vendor_format]
      Agent.update(h.counter, &Map.update!(&1, :speech, fn n -> n + 1 end))
      send(owner, {:tts_speech, body})
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
      {Azure, :synthesize, 2},
      {Azure, :build_request, 2},
      {Req, :request, 1},
      {Media, :put_audio, 3},
      {MediaDelivery, :publish, 4}
    ]

    for {module, function, arity} <- calls do
      Code.ensure_loaded!(module)
      spec = if module == Azure, do: [{:_, [], [{:return_trace}]}], else: true
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

    assert [{effect, Azure, :synthesize, [request, config]}] =
             Enum.filter(calls, &match?({_, Azure, :synthesize, _}, &1))

    assert [{^effect, TTS, :execute, [operation]}] =
             Enum.filter(calls, &match?({_, TTS, :execute, _}, &1))

    assert is_function(operation.backend_context.effect_deadline, 0)
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
    assert config[:timeout_ms] == h.source_timeout
    assert Map.has_key?(config, :timeout_ms) == (h.source_timeout != nil)
    assert config[:max_bytes] == h.max_bytes
    assert config[:api_key] == "current-azure-speech-fixture"

    assert config[:base_url] == Gaoxy.Test.url(h.speech_fixture, "/tenant")

    built = for {:returned, ^effect, Azure, :build_request, {:ok, value}} <- calls, do: value

    assert Enum.any?(built, fn built ->
             built.body == h.expected_body and
               built.timeout_ms == (h.source_timeout || request.timeout_ms)
           end)

    assert [{:returned, ^effect, Azure, :synthesize, {:ok, output}}] =
             Enum.filter(calls, &match?({:returned, ^effect, Azure, :synthesize, _}, &1))

    assert output == %{
             audio: h.audio,
             media_format: h.format,
             output_format: h.vendor_format,
             file_extension: "." <> h.format,
             voice_compatible: h.voice_compatible
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
        name: "Azure Speech"
      )

    assert {:ok, audio_dump} = Synapsis.Part.dump(audio)

    File.write!(
      "/tmp/synapsis-azure336-evidence/native-#{h.format}-projection.json",
      Jason.encode!(
        %{
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
