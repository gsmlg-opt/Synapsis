defmodule Synapsis.Session.NativeVydraTTSFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.MediaDelivery
  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Agent.Tools.TTS
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.{MessageMapper, Speech.Vydra, ToolName}
  alias Synapsis.Runtime.Store, as: RuntimeStore
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}
  alias Synapsis.Workspace.Media
  alias Synapsis.{AgentConfigs, Credentials, Models, Providers}

  @moduletag :tmp_dir
  @moduletag timeout: 90_000
  @name "synapsis::tts"
  @call_id "ordinary-vydra-tts"
  @text "Hello from the ordinary Vydra speech fixture."
  @spoken "(spoken) " <> @text
  # Opaque bytes qualify conservation and presentation, not decoding or playback.
  @mp3 <<255, 251, 144, "ordinary Vydra MP3", 0, 7>>
  @wav <<"RIFF", 0, 255, "ordinary Vydra WAV", 8>>

  # Expectations come from pinned speech-provider.ts/defaults.ts and the frozen
  # host architecture, independently of the new host service and capture output.
  for {label, options, input, fixture} <- [
        {"mp3-default", %{}, %{"text" => @text},
         %{
           base_path: "/api/v1",
           endpoint_path: "/api/v1/models/elevenlabs/tts",
           config: %{},
           body: %{"text" => @text, "voice_id" => "21m00Tcm4TlvDq8ikWAM"},
           download_mime: "audio/mpeg",
           output_format: "mp3",
           format: "mp3",
           mime: "audio/mpeg",
           audio: @mp3,
           timeout: 30_000,
           native_timeout: 65_000
         }},
        {"wav-agent-timeout", %{"timeout_ms" => 45_000}, %{"text" => @text},
         %{
           base_path: "/ordinary/vydra/v7///",
           endpoint_path: "/ordinary/vydra/v7/models/Custom/ElevenLabs",
           config: %{"model" => " Custom/ElevenLabs ", "voiceId" => " saved-rachel "},
           body: %{"text" => @text, "voice_id" => "saved-rachel"},
           download_mime: "audio/wav",
           output_format: "wav",
           format: "wav",
           mime: "audio/wav",
           audio: @wav,
           timeout: 45_000,
           native_timeout: 95_000
         }},
        {"uppercase-wav-tool-timeout",
         %{"timeout_ms" => 45_000, "model" => " Agent/Model ", "voice_id" => " agent-voice "},
         %{"text" => "  " <> @text <> "  ", "channel" => "", "timeoutMs" => 75_000},
         %{
           base_path: "/custom/vydra///",
           endpoint_path: "/custom/vydra/models/Agent/Model",
           config: %{"model" => "Saved/Model", "voiceId" => "saved-voice"},
           body: %{"text" => @text, "voice_id" => "agent-voice"},
           download_mime: "Audio/WAV",
           output_format: "mp3",
           format: "wav",
           mime: "audio/wav",
           audio: @wav,
           timeout: 75_000,
           native_timeout: 155_000
         }},
        {"mpeg-wave-parameter", %{}, %{"text" => @text},
         %{
           base_path: "/api/v1",
           endpoint_path: "/api/v1/models/elevenlabs/tts",
           config: %{"voice_id" => " saved-snake-voice "},
           body: %{"text" => @text, "voice_id" => "saved-snake-voice"},
           download_mime: "audio/mpeg;name=wave",
           output_format: "wav",
           format: "mp3",
           mime: "audio/mpeg",
           audio: @mp3,
           timeout: 30_000,
           native_timeout: 65_000
         }}
      ] do
    @label label
    @options options
    @input input
    @fixture fixture
    test "#{label}: one native effect persists audio and a distinct Worker replays the original fact",
         %{tmp_dir: root} do
      h = harness(root, @options, @fixture)
      install(h, @input)
      trace_effects()
      SessionHarness.subscribe!(h.session.id)
      SessionHarness.ensure_running!(h.session.id)
      assert :ok = Worker.send_message(h.session.id, "Speak the ordinary fixture text")

      assert_receive {:tts_outer, 0, initial}, 5_000
      assert_receive {:tts_descriptor, tool, locator}, 5_000
      assert tool.backend == TTS
      assert tool.codex_exposure == :direct_model_only
      assert tool.backend_context.timing.stage_count == 2
      assert [%{"name" => name, "input_schema" => schema}] = initial["tools"]
      assert ToolName.decode(name) == @name
      assert schema == tool.schema
      assert schema["required"] == ["text"]
      assert Map.keys(schema["properties"]) |> Enum.sort() == ~w(channel text timeoutMs)
      assert {:ok, []} = Models.list(provider_id: h.speech.id)
      assert_receive {:tts_http, :post, request}, 10_000
      assert request == @fixture.body
      assert_receive {:tts_http, :get, "/assets/first"}, 10_000
      assert_receive {:tts_outer, 1, following}, 10_000
      assert_receive {:tts_native_settled, [native]}, 5_000
      assert native.is_error == false
      assert native.content == [%{type: "text", text: @spoken}]
      assert_receive {:run_event, %{type: "session.completed"}}, 20_000

      [use, result] = parts(h.session.id)
      assert %ToolUse{tool: @name, tool_use_id: @call_id, input: @input} = use
      assert %ToolResult{is_error: false, tool_use_id: @call_id, content: @spoken} = result
      details = result.projection["result"]["details"]
      assert details == Jason.decode!(Jason.encode!(native.details))
      assert details["provider"] == "vydra"
      assert Map.get(details, "timeoutMs") == @input["timeoutMs"]
      assert Map.has_key?(details, "timeoutMs") == Map.has_key?(@input, "timeoutMs")
      audio = h.audio
      sha = Base.encode16(:crypto.hash(:sha256, audio), case: :lower)
      uri = "synapsis-media://audio/#{sha}.#{h.format}"

      descriptor = %{
        "uri" => uri,
        "sha256" => sha,
        "byte_size" => byte_size(audio),
        "mime_type" => h.mime,
        "format" => h.format
      }

      assert details["mediaDescriptor"] == descriptor
      assert details["audioPath"] == uri
      assert details["media"] == %{"mediaUrl" => uri, "trustedLocalMedia" => true}
      delivery = details["mediaDelivery"]
      assert %{"version" => 1, "session_id" => session_id, "id" => delivery_id} = delivery
      assert session_id == h.session.id
      assert map_size(delivery) == 3
      assert {:ok, ^delivery_id} = Ecto.UUID.cast(delivery_id)
      assert {:ok, fact} = RuntimeStore.get_fact(session_id, :audio_delivery, delivery_id)
      assert fact.descriptor == descriptor
      assert fact.root == h.media_root
      assert fact.max_bytes == h.max_bytes
      assert fact.invocation.tool_name == @name
      assert fact.invocation.tool_call_id == @call_id

      assert {:ok, %{audio: ^audio, descriptor: ^descriptor}} =
               MediaDelivery.read(session_id, delivery_id)

      assert {:ok, %{audio: ^audio, descriptor: ^descriptor}} =
               Media.read_audio(uri, root: h.media_root)

      assert [audio_path] = Path.wildcard(Path.join(h.media_root, "**/*.#{h.format}"))
      original_stat = File.stat!(audio_path, time: :posix)
      assert File.read!(audio_path) == audio
      assert_text_wire(following, @input)
      assert_round_trip_and_store(session_id, [use, result])
      assert_four_protocol_history(use, result, descriptor, delivery)
      aggregate = assert_runtime_aggregate(locator, native)

      assert {:ok, _} =
               AgentConfigs.update(h.configured_agent, %{
                 config:
                   Map.put(
                     h.configured_agent.config,
                     "tts",
                     Map.merge(h.tts, %{
                       "media_root" => Path.join(root, "new-audio-root"),
                       "max_bytes" => 8_192,
                       "model" => "Changed/CurrentModel",
                       "voice_id" => "changed-current-voice"
                     })
                   )
               })

      assert {:ok, _} =
               Providers.update(h.speech.id, %{
                 config: %{
                   "model" => "Changed/SavedModel",
                   "voiceId" => "changed-saved-voice"
                 }
               })

      [{old, _}] = Registry.lookup(Synapsis.Session.Registry, session_id)
      monitor = Process.monitor(old)
      assert :ok = DynamicSupervisor.stop_session(session_id)
      assert_receive {:DOWN, ^monitor, :process, ^old, _}, 5_000
      SessionHarness.ensure_running!(session_id)
      [{new, _}] = Registry.lookup(Synapsis.Session.Registry, session_id)
      refute new == old
      assert :ok = Worker.send_message(session_id, "Recall the completed speech")
      assert_receive {:tts_outer, 2, replay}, 10_000
      assert_receive {:run_event, %{type: "session.completed"}}, 20_000
      assert_text_wire(replay, @input)
      assert parts(session_id) == [use, result]
      assert_round_trip_and_store(session_id, [use, result])
      assert {:ok, ^fact} = RuntimeStore.get_fact(session_id, :audio_delivery, delivery_id)
      assert {:ok, [^fact]} = RuntimeStore.list_facts(session_id, :audio_delivery)

      assert {:ok, %{audio: ^audio, descriptor: ^descriptor}} =
               MediaDelivery.read(session_id, delivery_id)

      assert {:ok, %{audio: ^audio, descriptor: ^descriptor}} =
               Media.read_audio(uri, root: h.media_root)

      replay_stat = File.stat!(audio_path, time: :posix)

      assert {replay_stat.inode, replay_stat.mtime, replay_stat.size} ==
               {original_stat.inode, original_stat.mtime, original_stat.size}

      assert File.read!(audio_path) == audio
      assert %{http: [:post, :get], outer: 3} = Agent.get(h.counter, & &1)
      assert {:ok, ^aggregate} = RuntimeStore.load(locator.namespace, locator.run_id)
      assert_once_each_effect(h, descriptor, delivery, fact)
      export_projection(@label, h, use, result, descriptor, delivery)
    end
  end

  defp harness(root, options, fixture) do
    h =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(h) end)
    local = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(local) end)

    assert {:ok, credential} =
             Credentials.create(%{
               name: "vydra-credential-#{Ecto.UUID.generate()}",
               key: "initial-vydra-fixture"
             })

    on_exit(fn -> Credentials.delete(credential.id) end)

    assert {:ok, speech} =
             Providers.create(%{
               name: "ordinary-speech-#{Ecto.UUID.generate()}",
               type: "vydra_speech",
               preset: "vydra-speech",
               base_url: Gaoxy.Test.url(local, fixture.base_path),
               credential_id: credential.id,
               config: fixture.config
             })

    assert {:ok, _} = Ecto.UUID.cast(speech.id)
    on_exit(fn -> Providers.delete(speech.id) end)
    assert {:ok, _} = Credentials.update(credential.id, %{key: "current-vydra-fixture"})
    media_root = Path.join(root, "durable-audio")
    tts = Map.merge(%{"provider" => speech.name, "media_root" => media_root}, options)

    assert {:ok, configured_agent} =
             AgentConfigs.update(h.agent_config, %{
               tools: [@name],
               config: Map.put(h.agent_config.config, "tts", tts)
             })

    assert :ok =
             Synapsis.Provider.Registry.register(h.provider.name, %{
               type: "anthropic",
               base_url: h.provider.base_url,
               api_key: "fixture"
             })

    Agent.update(h.counter, &Map.merge(&1, %{http: [], outer: 0}))

    Map.merge(
      h,
      Map.merge(fixture, %{
        speech: speech,
        speech_fixture: local,
        configured_agent: configured_agent,
        tts: tts,
        media_root: media_root,
        max_bytes: 16 * 1024 * 1024
      })
    )
  end

  defp install(h, input) do
    owner = self()
    first = Gaoxy.Test.url(h.speech_fixture, "/assets/first")
    second = Gaoxy.Test.url(h.speech_fixture, "/assets/second")

    Gaoxy.Test.stub(h.speech_fixture, "POST", h.endpoint_path, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      Agent.update(h.counter, &Map.update!(&1, :http, fn xs -> xs ++ [:post] end))
      send(owner, {:tts_http, :post, Jason.decode!(body)})

      payload = %{
        "audioUrl" => "  " <> first <> "  ",
        "audioUrls" => [first, second],
        "output" => %{"audioUrl" => second}
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)

    Gaoxy.Test.stub(h.speech_fixture, "GET", "/assets/first", fn conn ->
      Agent.update(h.counter, &Map.update!(&1, :http, fn xs -> xs ++ [:get] end))
      send(owner, {:tts_http, :get, conn.request_path})

      conn
      |> Plug.Conn.put_resp_header("content-type", h.download_mime)
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

  defp parts(id) do
    for message <- Synapsis.Message.list_by_session(id),
        part <- message.parts,
        match?(%ToolUse{tool: @name}, part) or match?(%ToolResult{tool_use_id: @call_id}, part),
        do: part
  end

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

  defp assert_round_trip_and_store(id, [use, result] = parts) do
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

  defp assert_four_protocol_history(use, result, descriptor, delivery) do
    audio =
      struct(Synapsis.Part.Audio, descriptor: descriptor, delivery: delivery, name: "Vydra audio")

    summary =
      "Delivered audio: Vydra audio\nURI: #{descriptor["uri"]}\n" <>
        "MIME: #{descriptor["mime_type"]}\nDelivery: v1 #{delivery["session_id"]}/#{delivery["id"]}"

    assert Synapsis.Part.Audio.summary(audio) == summary

    for protocol <- [:anthropic, :openai, :openai_responses, :google] do
      messages = [
        %{role: "assistant", parts: [use]},
        %{role: "tool", parts: [result]},
        %{role: "assistant", parts: [audio]}
      ]

      assert {:ok, wire} =
               MessageMapper.build_request(protocol, messages, [], %{model: "fixture"})

      plain = %{result | projection: nil}

      expected = [
        %{role: "assistant", parts: [use]},
        %{role: "tool", parts: [plain]},
        %{role: "assistant", parts: [%Synapsis.Part.Text{content: summary}]}
      ]

      assert {:ok, expected_wire} =
               MessageMapper.build_request(protocol, expected, [], %{model: "fixture"})

      assert wire == expected_wire
      assert @spoken in strings(wire)
      assert summary in strings(wire)
    end
  end

  defp strings(value) when is_binary(value), do: [value]
  defp strings(value) when is_list(value), do: Enum.flat_map(value, &strings/1)
  defp strings(value) when is_map(value), do: Enum.flat_map(value, fn {_, v} -> strings(v) end)
  defp strings(_), do: []

  defp trace_effects do
    calls = [
      {TTS, :execute, 1},
      {Vydra, :synthesize, 2},
      {Req, :request, 1},
      {Media, :put_audio, 3},
      {MediaDelivery, :publish, 4}
    ]

    for {module, function, arity} <- calls do
      Code.ensure_loaded!(module)
      spec = if module == Vydra, do: [{:_, [], [{:return_trace}]}], else: true
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

  defp assert_once_each_effect(h, descriptor, delivery, fact) do
    calls = traced_calls()

    assert [{effect, Vydra, :synthesize, [request, config]}] =
             Enum.filter(calls, &match?({_, Vydra, :synthesize, _}, &1))

    assert [{^effect, TTS, :execute, [operation]}] =
             Enum.filter(calls, &match?({_, TTS, :execute, _}, &1))

    assert is_function(operation.backend_context.effect_deadline, 0)
    deadlines = for {:returned, ^effect, GenServer, :call, {:ok, value}} <- calls, do: value
    assert deadlines != []

    for native <- deadlines do
      assert native.selected_timeout_ms == h.native_timeout
      assert native.paused == false
      assert native.remaining_ms > 0
      assert native.remaining_ms <= native.selected_timeout_ms
      assert is_integer(native.deadline_ms)
    end

    [native | _] = deadlines
    assert Enum.all?(deadlines, &(&1.deadline_ms == native.deadline_ms))
    assert request.text == @text
    assert request.target == :audio_file
    assert request.timeout_ms == h.timeout
    assert request.deadline_ms == native.deadline_ms
    assert config[:max_bytes] == h.max_bytes
    assert config[:api_key] == "current-vydra-fixture"

    assert String.trim_trailing(config[:base_url], "/") ==
             String.trim_trailing(h.speech.base_url, "/")

    assert [{:returned, ^effect, Vydra, :synthesize, {:ok, output}}] =
             Enum.filter(calls, &match?({:returned, ^effect, Vydra, :synthesize, _}, &1))

    assert output == %{
             audio: h.audio,
             output_format: h.output_format,
             file_extension: "." <> h.format,
             media_format: h.format,
             voice_compatible: false
           }

    base = Gaoxy.Test.url(h.speech_fixture)

    http =
      for {_, Req, :request, [%Req.Request{} = req]} <- calls,
          String.starts_with?(URI.to_string(req.url), base),
          do: req

    assert [post, get] = http
    assert post.method == :post
    assert URI.to_string(post.url) == Gaoxy.Test.url(h.speech_fixture, h.endpoint_path)
    assert get.method == :get
    assert URI.to_string(get.url) == Gaoxy.Test.url(h.speech_fixture, "/assets/first")

    for req <- http do
      # Each ordinary successful stage gets T, clipped only by its own elapsed
      # setup or the same native deadline. No delayed/expiration experiment.
      for duration <- [
            req.options[:receive_timeout],
            req.options[:request_timeout],
            req.options[:finch][:pool_timeout]
          ] do
        assert is_integer(duration)
        assert duration > h.timeout - 5_000
        assert duration <= h.timeout
      end
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
              [^descriptor, session_id, published, delivery_opts]}
           ] =
             Enum.filter(calls, &match?({_, MediaDelivery, :publish, _}, &1))

    assert session_id == h.session.id
    assert delivery_opts[:root] == h.media_root
    assert delivery_opts[:max_bytes] == config[:max_bytes]

    assert fact.invocation ==
             Map.take(published, [:run_id, :invocation_id, :tool_call_id, :tool_name])

    assert {:ok, ^fact} = RuntimeStore.get_fact(session_id, :audio_delivery, delivery["id"])
  end

  defp export_projection(label, h, use, result, descriptor, delivery) do
    assert {:ok, use_dump} = Synapsis.Part.dump(use)
    assert {:ok, result_dump} = Synapsis.Part.dump(result)

    audio =
      struct(Synapsis.Part.Audio, descriptor: descriptor, delivery: delivery, name: "Vydra audio")

    assert {:ok, audio_dump} = Synapsis.Part.dump(audio)

    payload = %{
      scenario: label,
      descriptor: descriptor,
      delivery: delivery,
      audioBase64: Base.encode64(h.audio),
      toolUse: use_dump,
      initial: %{toolResult: result_dump, audioPart: audio_dump},
      history: %{toolResult: result_dump, audioPart: audio_dump}
    }

    File.write!(
      "/tmp/synapsis-vydra330-evidence/native-#{label}-projection.json",
      Jason.encode!(payload, pretty: true)
    )
  end
end
