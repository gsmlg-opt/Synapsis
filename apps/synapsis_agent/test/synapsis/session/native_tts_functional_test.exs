defmodule Synapsis.Session.NativeTTSFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Agent.MediaDelivery
  alias Synapsis.Agent.Tools.{DisplayCatalog, Profiles, TTS}
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.{Speech.OpenAI, ToolName}
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
  # One mono, 16-bit PCM sample at 8 kHz, with a complete RIFF/WAVE header.
  @wav <<"RIFF", 38::little-32, "WAVEfmt ", 16::little-32, 1::little-16, 1::little-16,
         8_000::little-32, 16_000::little-32, 2::little-16, 16::little-16, "data", 2::little-32,
         0::little-16>>

  for {label, options, input, expected, provider_fixture} <- [
        {"default model and voice", %{}, %{"text" => @text},
         %{"model" => "gpt-4o-mini-tts", "voice" => "coral"},
         %{type: "openai_compat", base_path: "/v1", endpoint_path: "/v1/audio/speech"}},
        {"configured speech options and explicit timeout",
         %{
           "model" => "ordinary-speech-model",
           "voice" => "ordinary-voice",
           "speed" => 1.25,
           "instructions" => "Speak at an ordinary measured pace.",
           "max_bytes" => 1_024
         }, %{"text" => "  " <> @text <> "  ", "channel" => "", "timeoutMs" => 12_000},
         %{
           "model" => "ordinary-speech-model",
           "voice" => "ordinary-voice",
           "speed" => 1.25,
           "instructions" => "Speak at an ordinary measured pace."
         },
         %{
           type: "openai_responses",
           base_path: "/custom/api/v1/",
           endpoint_path: "/custom/api/v1/audio/speech"
         }},
        {"saved OpenAI API root", %{}, %{"text" => @text},
         %{"model" => "gpt-4o-mini-tts", "voice" => "coral"},
         %{type: "openai", base_path: "/", endpoint_path: "/v1/audio/speech"}},
        {"dedicated OpenAI Speech provider", %{}, %{"text" => @text},
         %{"model" => "gpt-4o-mini-tts", "voice" => "coral"},
         %{type: "openai_speech", base_path: "/", endpoint_path: "/v1/audio/speech"}},
        {"saved Groq API prefix", %{}, %{"text" => @text},
         %{"model" => "gpt-4o-mini-tts", "voice" => "coral"},
         %{type: "groq", base_path: "/openai", endpoint_path: "/openai/v1/audio/speech"}}
      ] do
    @options options
    @input input
    @expected expected
    @provider_fixture provider_fixture
    test "selected TTS with #{label} settles durable audio and replays success through a new Worker",
         %{tmp_dir: root} do
      h = harness(root, @options, @provider_fixture)
      install(h, @input)
      trace_effects()
      start(h)

      assert_receive {:tts_outer, 0, initial}, 5_000
      assert_receive {:tts_descriptor, descriptor}, 5_000
      assert descriptor.backend == TTS
      assert descriptor.codex_exposure == :direct_model_only
      assert [%{"name" => name, "input_schema" => schema}] = initial["tools"]
      assert ToolName.decode(name) == @name
      assert schema == descriptor.schema
      assert schema["required"] == ["text"]
      assert schema["properties"]["timeoutMs"]["minimum"] == 1
      refute Map.has_key?(schema["properties"]["timeoutMs"], "maximum")
      assert @name in Profiles.supported_names()
      assert length(Profiles.supported_names()) == 74
      assert [%{category: :media}] = Enum.filter(DisplayCatalog.list(), &(&1.name == @name))
      assert {:ok, []} = Models.list(provider_id: h.speech.id)

      assert_receive {:tts_speech, request}, 10_000
      assert request == Map.merge(@expected, %{"input" => @text, "response_format" => "wav"})
      assert_receive {:tts_outer, 1, following}, 10_000
      assert_receive {:tts_native_settled, [native]}, 5_000
      assert native.is_error == false
      assert native.content == [%{type: "text", text: @spoken}]
      assert_receive {:run_event, %{type: "session.completed"}}, 20_000

      [use, result] = tts_parts(h.session.id)
      assert %ToolUse{tool: @name, tool_use_id: @call_id} = use
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
      sha256 = Base.encode16(:crypto.hash(:sha256, @wav), case: :lower)
      assert uri == "synapsis-media://audio/" <> sha256 <> ".wav"

      assert descriptor == %{
               "uri" => uri,
               "sha256" => sha256,
               "byte_size" => byte_size(@wav),
               "mime_type" => "audio/wav",
               "format" => "wav"
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

      assert {:ok, %{audio: @wav, descriptor: ^descriptor}} =
               MediaDelivery.read(session_id, delivery_id)

      assert {:ok, %{audio: @wav, descriptor: ^descriptor}} =
               Media.read_audio(uri, root: h.media_root)

      assert [audio_path] = Path.wildcard(Path.join(h.media_root, "**/*.wav"))
      audio_stat = File.stat!(audio_path, time: :posix)
      assert File.read!(audio_path) == @wav
      assert_text_wire(following)
      assert_round_trip_and_store(h.session.id, [use, result], root)

      [{old, _}] = Registry.lookup(Synapsis.Session.Registry, h.session.id)
      monitor = Process.monitor(old)
      assert :ok = DynamicSupervisor.stop_session(h.session.id)
      assert_receive {:DOWN, ^monitor, :process, ^old, _}, 5_000

      current_agent = AgentConfigs.get_by_name(h.agent_name)

      changed_tts =
        current_agent.config["tts"]
        |> Map.put("media_root", Path.join(root, "new-audio-root"))
        |> Map.put("max_bytes", 1)

      assert {:ok, _} =
               AgentConfigs.update(current_agent, %{
                 config: Map.put(current_agent.config, "tts", changed_tts)
               })

      SessionHarness.ensure_running!(h.session.id)
      [{new, _}] = Registry.lookup(Synapsis.Session.Registry, h.session.id)
      refute new == old
      assert :ok = Worker.send_message(h.session.id, "Recall the completed speech")
      assert_receive {:tts_outer, 2, replay}, 10_000
      assert_receive {:run_event, %{type: "session.completed"}}, 20_000
      assert_text_wire(replay)
      assert tts_parts(h.session.id) == [use, result]
      assert_round_trip_and_store(h.session.id, [use, result], root)

      assert {:ok, ^fact} = RuntimeStore.get_fact(session_id, :audio_delivery, delivery_id)
      assert {:ok, [^fact]} = RuntimeStore.list_facts(session_id, :audio_delivery)

      assert {:ok, %{audio: @wav, descriptor: ^descriptor}} =
               MediaDelivery.read(session_id, delivery_id)

      assert {:ok, %{audio: @wav, descriptor: ^descriptor}} =
               Media.read_audio(uri, root: h.media_root)

      replay_stat = File.stat!(audio_path, time: :posix)

      assert {replay_stat.inode, replay_stat.mtime, replay_stat.size} ==
               {audio_stat.inode, audio_stat.mtime, audio_stat.size}

      assert File.read!(audio_path) == @wav
      assert %{speech: 1, outer: 3} = Agent.get(h.counter, & &1)
      assert_once_each_effect(h, @input, descriptor, delivery, fact)
    end
  end

  test "ordinary empty selection completes without installing a TTS descriptor", %{tmp_dir: root} do
    h = harness(root, %{})
    assert {:ok, _} = AgentConfigs.update(h.agent_config, %{tools: []})
    install(h, nil)
    trace_effects()
    start(h)
    assert_receive {:tts_outer, 0, request}, 5_000
    assert_receive {:tts_descriptor, nil}, 5_000
    assert Map.get(request, "tools", []) == []
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    assert tts_parts(h.session.id) == []
    assert %{speech: 0, outer: 1} = Agent.get(h.counter, & &1)
    assert traced_calls() == []
  end

  defp harness(
         root,
         options,
         provider_fixture \\ %{
           type: "openai_compat",
           base_path: "/v1",
           endpoint_path: "/v1/audio/speech"
         }
       ) do
    h =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(h) end)
    fixture = Gaoxy.Test.open()

    {:ok, speech} =
      Providers.create(%{
        name: "tts-speech-#{System.unique_integer([:positive])}",
        type: provider_fixture.type,
        base_url: Gaoxy.Test.url(fixture, provider_fixture.base_path),
        api_key_encrypted: "ordinary-speech-fixture"
      })

    on_exit(fn -> Providers.delete(speech.id) end)
    media_root = Path.join(root, "durable-audio")

    tts =
      Map.merge(
        %{"provider" => speech.name, "response_format" => "wav", "media_root" => media_root},
        options
      )

    config = Map.put(h.agent_config.config, "tts", tts)
    assert {:ok, _} = AgentConfigs.update(h.agent_config, %{tools: [@name], config: config})

    assert :ok =
             Synapsis.Provider.Registry.register(h.provider.name, %{
               type: "anthropic",
               base_url: h.provider.base_url,
               api_key: "fixture"
             })

    Agent.update(h.counter, &Map.merge(&1, %{speech: 0, outer: 0}))

    Map.merge(h, %{
      speech: speech,
      speech_fixture: fixture,
      speech_endpoint: provider_fixture.endpoint_path,
      media_root: media_root,
      max_bytes: Map.get(options, "max_bytes", 16 * 1024 * 1024)
    })
  end

  defp install(h, input) do
    owner = self()

    Gaoxy.Test.stub(h.speech_fixture, "POST", h.speech_endpoint, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      Agent.update(h.counter, &Map.update!(&1, :speech, fn n -> n + 1 end))
      send(owner, {:tts_speech, Jason.decode!(body)})
      conn |> Plug.Conn.put_resp_content_type("audio/wav") |> Plug.Conn.resp(200, @wav)
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
          do: send(owner, {:tts_descriptor, native.catalog.registry.tools[@name]}),
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

  defp assert_text_wire(request) do
    blocks =
      Enum.flat_map(request["messages"], &List.wrap(&1["content"])) |> Enum.filter(&is_map/1)

    assert [result] = Enum.filter(blocks, &(&1["type"] == "tool_result"))
    assert result["tool_use_id"] == @call_id
    assert result["is_error"] == false
    assert result["content"] == [%{"type" => "text", "text" => @spoken}]
  end

  defp assert_round_trip_and_store(id, [_, result] = parts, root) do
    for part <- parts do
      assert {:ok, dump} = Synapsis.Part.dump(part)
      assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
    end

    assert {:ok, turns} = Store.list_turns(id)

    for {turn, index} <- Enum.with_index(turns),
        do: assert({:ok, ^turn} = Store.get_turn(id, index))

    persisted = for turn <- turns, part <- turn.parts, part[:type] == "tool_result", do: part
    assert [stored] = persisted
    assert stored.content == result.content
    assert stored.projection == result.projection
    encoded = Jason.encode!(stored)
    refute encoded =~ root
    refute encoded =~ Base.encode64(@wav)
    refute encoded =~ "RIFF"
    assert byte_size(encoded) < 4_096
  end

  defp trace_effects do
    for {module, function, arity} <- [
          {OpenAI, :synthesize, 2},
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
            {OpenAI, :synthesize, 2},
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

    assert [{effect, OpenAI, :synthesize, [request, config]}] =
             Enum.filter(calls, &(elem(&1, 1) == OpenAI))

    assert request == %{
             text: @text,
             target: :audio_file,
             timeout_ms: Map.get(input, "timeoutMs", 30_000)
           }

    assert config[:max_bytes] == h.max_bytes

    assert [{^effect, Media, :put_audio, [@wav, "wav", opts]}] =
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
