defmodule Synapsis.Session.NativeInworldTTSFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Agent.MediaDelivery
  alias Synapsis.Agent.Tools.{DisplayCatalog, Profiles, TTS}
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.{Speech.Inworld, ToolName}
  alias Synapsis.Runtime.Store, as: RuntimeStore
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}
  alias Synapsis.Workspace.Media
  alias Synapsis.{AgentConfigs, Models, Providers}

  @moduletag :tmp_dir
  @moduletag timeout: 90_000
  @name "synapsis::tts"
  @call_id "ordinary-tts"
  @text "Hello from the ordinary speech fixture."
  @spoken "(spoken) " <> @text

  for {label, options, input, expected, provider_fixture} <- [
        {"default Inworld MP3", %{}, %{"text" => @text},
         %{
           "voiceId" => "Sarah",
           "modelId" => "inworld-tts-1.5-max",
           "audioConfig" => %{"audioEncoding" => "MP3"}
         }, %{base_path: "/", endpoint_path: "/tts/v1/voice:stream", config: %{}}},
        {"saved Inworld settings with Agent overrides and a custom prefix",
         %{
           "voice_id" => " Ashley ",
           "model_id" => " inworld-tts-1.5-mini ",
           "temperature" => 1.2,
           "max_bytes" => 8192
         }, %{"text" => "  " <> @text <> "  ", "channel" => "", "timeoutMs" => 12000},
         %{
           "voiceId" => "Ashley",
           "modelId" => "inworld-tts-1.5-mini",
           "temperature" => 1.2,
           "audioConfig" => %{"audioEncoding" => "MP3"}
         },
         %{
           base_path: "/speech/custom/v7///",
           endpoint_path: "/speech/custom/v7/tts/v1/voice:stream",
           config: %{
             "voice_id" => "Sarah",
             "model_id" => "inworld-tts-1-max",
             "temperature" => 0.8,
             "max_bytes" => 4096
           }
         }}
      ] do
    @options options
    @input input
    @expected expected
    @provider_fixture provider_fixture
    test "selected TTS with #{label} settles durable audio and replays success through a new Worker",
         %{tmp_dir: root} do
      h = harness(root, @options, @provider_fixture)
      audio = h.audio
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
      assert request == Map.put(@expected, "text", @text)
      assert_receive {:tts_outer, 1, following}, 10_000
      assert_receive {:tts_native_settled, [native]}, 5_000
      assert native.is_error == false
      assert native.content == [%{type: "text", text: @spoken}]
      assert_receive {:run_event, %{type: "session.completed"}}, 20_000

      [use, result] = tts_parts(h.session.id)
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
      assert_text_wire(following, @input)
      assert_round_trip_and_store(h.session.id, [use, result], root, audio)
      aggregate = assert_runtime_aggregate(locator, native)

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

    {:ok, speech} =
      Providers.create(%{
        name: "tts-speech-#{System.unique_integer([:positive])}",
        type: "inworld_speech",
        preset: "inworld-speech",
        base_url: Gaoxy.Test.url(fixture, provider_fixture.base_path),
        api_key_encrypted: "ordinary-speech-fixture",
        config: provider_fixture.config
      })

    on_exit(fn -> Providers.delete(speech.id) end)
    media_root = Path.join(root, "durable-audio")
    tts = Map.merge(%{"provider" => speech.name, "media_root" => media_root}, options)
    config = Map.put(h.agent_config.config, "tts", tts)
    assert {:ok, _} = AgentConfigs.update(h.agent_config, %{tools: [@name], config: config})

    assert :ok =
             Synapsis.Provider.Registry.register(h.provider.name, %{
               type: "anthropic",
               base_url: h.provider.base_url,
               api_key: "fixture"
             })

    Agent.update(h.counter, &Map.merge(&1, %{speech: 0, outer: 0}))

    audio =
      File.read!(
        Path.expand("../../../../synapsis_provider/test/fixtures/speech/tone.mp3", __DIR__)
      )

    merged_speech = Map.merge(provider_fixture.config, options)

    Map.merge(h, %{
      audio: audio,
      speech: speech,
      speech_fixture: fixture,
      speech_endpoint: provider_fixture.endpoint_path,
      media_root: media_root,
      expected_speech: merged_speech,
      max_bytes: Map.get(merged_speech, "max_bytes", 16 * 1024 * 1024)
    })
  end

  defp install(h, input) do
    owner = self()

    Gaoxy.Test.stub(h.speech_fixture, "POST", h.speech_endpoint, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params == %{}
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      Agent.update(h.counter, &Map.update!(&1, :speech, fn n -> n + 1 end))
      send(owner, {:tts_speech, Jason.decode!(body)})
      <<first::binary-size(31), rest::binary>> = h.audio

      ndjson =
        "\n" <>
          Jason.encode!(%{result: %{audioContent: Base.encode64(first)}}) <>
          "\n" <>
          Jason.encode!(%{metadata: %{requestId: "ordinary-native-speech"}}) <>
          "\n\n" <> Jason.encode!(%{result: %{audioContent: Base.encode64(rest)}}) <> "\n"

      conn
      |> Plug.Conn.put_resp_content_type("application/x-ndjson")
      |> Plug.Conn.resp(200, ndjson)
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

  defp assert_round_trip_and_store(id, [use, result] = parts, root, audio) do
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
    persisted = for turn <- turns, part <- turn.parts, part[:type] == "tool_result", do: part
    assert [stored] = persisted
    assert stored.content == result.content
    assert stored.projection == result.projection
    encoded = Jason.encode!(stored)
    refute encoded =~ root
    refute encoded =~ Base.encode64(audio)
  end

  defp trace_effects do
    for {module, function, arity} <- [
          {Inworld, :synthesize, 2},
          {Media, :put_audio, 3},
          {MediaDelivery, :publish, 4}
        ] do
      Code.ensure_loaded!(module)
      :erlang.trace_pattern({module, function, arity}, true, [:local])
    end

    :erlang.trace(:all, true, [:call, {:tracer, self()}])

    on_exit(fn ->
      :erlang.trace(:all, false, [:call])

      for {module, function, arity} <- [
            {Inworld, :synthesize, 2},
            {Media, :put_audio, 3},
            {MediaDelivery, :publish, 4}
          ],
          do: :erlang.trace_pattern({module, function, arity}, false, [:local])
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
    after
      0 -> Enum.reverse(calls)
    end
  end

  defp assert_once_each_effect(h, input, descriptor, delivery, fact) do
    calls = traced_calls()

    assert [{effect, Inworld, :synthesize, [request, config]}] =
             Enum.filter(calls, &(elem(&1, 1) == Inworld))

    assert Map.take(request, [:text, :target, :timeout_ms]) == %{
             text: @text,
             target: :audio_file,
             timeout_ms: Map.get(input, "timeoutMs", 30_000)
           }

    assert Map.get(request, :provider_overrides, %{}) == %{}
    assert config[:base_url] == h.speech.base_url
    assert config[:max_bytes] == h.max_bytes

    for {string, atom} <- [
          {"voice_id", :voice_id},
          {"model_id", :model_id},
          {"temperature", :temperature}
        ],
        Map.has_key?(h.expected_speech, string),
        do: assert(config[atom] == h.expected_speech[string])

    audio = h.audio

    assert [{^effect, Media, :put_audio, [^audio, "mp3", opts]}] =
             Enum.filter(calls, &(elem(&1, 1) == Media))

    assert opts[:root] == h.media_root
    assert opts[:max_bytes] == config[:max_bytes]
    assert is_integer(opts[:deadline])

    assert [
             {^effect, MediaDelivery, :publish,
              [^descriptor, session_id, operation, delivery_opts]}
           ] =
             Enum.filter(calls, &(elem(&1, 1) == MediaDelivery))

    assert session_id == h.session.id
    assert delivery_opts[:root] == h.media_root
    assert delivery_opts[:max_bytes] == config[:max_bytes]

    assert fact.invocation ==
             Map.take(operation, [:run_id, :invocation_id, :tool_call_id, :tool_name])

    assert {:ok, ^fact} = RuntimeStore.get_fact(session_id, :audio_delivery, delivery["id"])
  end
end
