defmodule SynapsisWeb.AgentLive.AudioDeliveryFunctionalTest do
  use SynapsisWeb.ConnCase, async: false

  alias Synapsis.Agent.{MediaDelivery, TestSupport.SessionHarness}
  alias Synapsis.Agent.Tools.ResultProjection
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}
  alias Synapsis.Session.Worker.Persistence
  alias Synapsis.{AgentConfigs, Providers}

  @moduletag :tmp_dir
  @moduletag timeout: 90_000
  @name "synapsis::tts"
  @call_id "chat-native-audio"
  @text "Hello from the durable speech fixture."
  @spoken "(spoken) " <> @text
  @pcm (for sample <- 0..7_999, into: <<>> do
          value = round(:math.sin(2 * :math.pi() * 440 * sample / 8_000) * 12_000)
          <<value::signed-little-16>>
        end)
  @wav <<"RIFF", 36 + byte_size(@pcm)::little-32, "WAVEfmt ", 16::little-32, 1::little-16,
         1::little-16, 8_000::little-32, 16_000::little-32, 2::little-16, 16::little-16, "data",
         byte_size(@pcm)::little-32, @pcm::binary>>

  @fixtures Path.expand("../../../../../synapsis_provider/test/fixtures/speech", __DIR__)
  @mp3 File.read!(Path.join(@fixtures, "tone.mp3"))
  @opus File.read!(Path.join(@fixtures, "tone.opus"))

  for {format, mime, bytes} <- [
        {"wav", "audio/wav", @wav},
        {"mp3", "audio/mpeg", @mp3},
        {"opus", "audio/ogg", @opus}
      ] do
    @format format
    @mime mime
    @audio bytes

    test "#{format} speech reaches live chat, original-root HTTP, Concord, new Worker history and replay",
         %{conn: conn, tmp_dir: root} do
      h =
        SessionHarness.setup_session!(
          tmp_dir: root,
          install_provider?: false,
          session_config: %{"subagents" => false, "memory_context" => false}
        )

      on_exit(fn -> SessionHarness.cleanup!(h) end)
      speech_fixture = Gaoxy.Test.open()

      assert {:ok, speech} =
               Providers.create(%{
                 name: "audio-chat-#{System.unique_integer([:positive])}",
                 type: "openai_compat",
                 base_url: Gaoxy.Test.url(speech_fixture, "/v1"),
                 api_key_encrypted: "ordinary-speech-fixture"
               })

      on_exit(fn -> Providers.delete(speech.id) end)
      media_root = Path.join(root, "original-audio")

      tts = %{
        "provider" => speech.name,
        "response_format" => @format,
        "media_root" => media_root,
        "max_bytes" => byte_size(@audio) + 1
      }

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

      Agent.update(h.counter, &Map.put(&1, :speech, 0))
      owner = self()

      Gaoxy.Test.stub(speech_fixture, "POST", "/v1/audio/speech", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        Agent.update(h.counter, &Map.update!(&1, :speech, fn n -> n + 1 end))
        send(owner, {:audio_speech, Jason.decode!(body)})
        conn |> Plug.Conn.put_resp_content_type(@mime) |> Plug.Conn.resp(200, @audio)
      end)

      Gaoxy.Test.stub(h.provider.fixture, "POST", "/v1/messages", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        index =
          Agent.get_and_update(h.counter, fn state ->
            {length(state.provider_requests),
             %{state | provider_requests: state.provider_requests ++ [request]}}
          end)

        send(owner, {:audio_chat_request, index, request, self()})

        if index == 0 do
          outer_response(conn, %{"text" => @text})
        else
          receive do
            :complete -> outer_response(conn, nil)
          after
            10_000 -> raise "fixture completion was not released"
          end
        end
      end)

      SessionHarness.subscribe!(h.session.id)
      route = ~p"/agent/agents/#{h.agent_name}/sessions/#{h.session.id}"
      {:ok, view, _} = live(conn, route)
      assert :ok = Worker.send_message(h.session.id, "Speak the ordinary fixture text")
      assert_receive {:audio_chat_request, 0, _initial, _}, 5_000
      assert_receive {:audio_speech, speech_request}, 10_000
      assert speech_request["input"] == @text
      assert speech_request["response_format"] == @format
      assert_receive {:audio_chat_request, 1, following, provider}, 10_000

      live_chat = chat(view)
      tool = live_chat.messages |> Enum.flat_map(& &1.tools) |> Enum.find(&(&1.id == @call_id))
      assert tool.status == "complete"
      assert %{blocks: [%{type: "text", text: @spoken}, audio], isError: false} = tool.display
      assert audio.type == "audio"
      assert audio.mediaType == @mime
      assert audio.filename == "audio.#{@format}"
      assert_wire_text(following)

      details = Enum.find(tool.display.sidecars, &(&1.key == "details")).value
      descriptor = details["mediaDescriptor"]
      assert descriptor == descriptor(@audio, @format, @mime)
      delivery = details["mediaDelivery"]
      assert Map.keys(delivery) |> Enum.sort() == ~w(id session_id version)
      assert delivery["session_id"] == h.session.id
      assert delivery["version"] == 1
      assert {:ok, path} = MediaDelivery.url(delivery)
      assert audio.src == path

      assert {:ok, fact} =
               Synapsis.Runtime.Store.get_fact(h.session.id, "audio_delivery", delivery["id"])

      assert fact.root == media_root
      assert fact.max_bytes == tts["max_bytes"]
      assert fact.descriptor == descriptor
      assert fact.invocation.tool_call_id == @call_id
      assert fact.invocation.tool_name == @name
      port = http_listener()
      assert_audio_http(port, path, @audio, @format, @mime)
      [audio_path] = Path.wildcard(Path.join(media_root, "**/*.#{@format}"))
      audio_stat = File.stat!(audio_path, time: :posix)

      send(provider, :complete)
      assert_receive {:run_event, %{type: "session.completed"}}, 20_000
      result = stored_result(h.session.id)
      assert result.content == @spoken
      assert result.projection["result"]["content"] == [%{"type" => "text", "text" => @spoken}]
      assert result.projection["result"]["details"] == details
      assert {:ok, loaded} = result |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
      assert {:ok, dumped} = Synapsis.Part.dump(loaded)
      assert {:ok, ^loaded} = dumped |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
      assert {:ok, [^fact]} = Synapsis.Runtime.Store.list_facts(h.session.id, "audio_delivery")

      changed_tts =
        Map.merge(tts, %{"media_root" => Path.join(root, "new-audio"), "max_bytes" => 1})

      assert {:ok, _} =
               AgentConfigs.update(configured_agent, %{
                 config: Map.put(configured_agent.config, "tts", changed_tts)
               })

      assert_audio_http(port, path, @audio, @format, @mime)
      [{old_worker, _}] = Registry.lookup(Synapsis.Session.Registry, h.session.id)
      monitor = Process.monitor(old_worker)
      assert :ok = DynamicSupervisor.stop_session(h.session.id)
      assert_receive {:DOWN, ^monitor, :process, ^old_worker, _}, 5_000
      {:ok, history_view, _} = live(conn, route)
      history_chat = chat(history_view)
      assert result_part(history_chat).display == tool.display

      SessionHarness.ensure_running!(h.session.id)
      [{new_worker, _}] = Registry.lookup(Synapsis.Session.Registry, h.session.id)
      refute new_worker == old_worker
      assert :ok = Worker.send_message(h.session.id, "Recall the completed speech")
      assert_receive {:audio_chat_request, 2, replay, replay_provider}, 10_000
      assert_wire_text(replay)
      send(replay_provider, :complete)
      assert_receive {:run_event, %{type: "session.completed"}}, 20_000
      replay_chat = chat(history_view)
      assert result_part(replay_chat).display == tool.display
      assert stored_result(h.session.id) == result
      assert {:ok, [^fact]} = Synapsis.Runtime.Store.list_facts(h.session.id, "audio_delivery")
      assert_audio_http(port, path, @audio, @format, @mime)
      assert %{speech: 1, provider_requests: [_, _, _]} = Agent.get(h.counter, & &1)
      replay_stat = File.stat!(audio_path, time: :posix)

      assert {replay_stat.inode, replay_stat.mtime, replay_stat.size} ==
               {audio_stat.inode, audio_stat.mtime, audio_stat.size}

      export(
        %{live: live_chat, history: history_chat, replay: replay_chat},
        @audio,
        @format,
        @mime
      )
    end
  end

  test "descriptor-only legacy speech keeps its transcript and explicitly displays delivery unavailable" do
    descriptor = descriptor(@wav, "wav", "audio/wav")

    assert {:ok, part} =
             ResultProjection.to_part("old-speech", %{
               content: [%{type: "text", text: @spoken}],
               details: %{mediaDescriptor: descriptor}
             })

    display = SynapsisWeb.ToolResultView.present(part)
    assert [%{type: "text", text: @spoken}, unavailable] = display.blocks
    assert unavailable.type == "reference"
    assert unavailable.kind == "audio-delivery-unavailable"
    assert unavailable.label == "Audio delivery unavailable"

    assert Enum.find(display.sidecars, &(&1.key == "details")).value["mediaDescriptor"] ==
             descriptor
  end

  test "code-agent speech uses the same ordered audio display and preserved details", %{
    conn: conn
  } do
    assert {:ok, session} =
             Synapsis.Sessions.create("__global__", %{
               agent: "main",
               provider: "anthropic",
               model: "fixture",
               config: %{"subagents" => false}
             })

    on_exit(fn ->
      DynamicSupervisor.stop_session(session.id)
      Synapsis.Sessions.delete(session.id)
    end)

    {:ok, view, _} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")
    sub_id = Ecto.UUID.generate()
    descriptor = descriptor(@wav, "wav", "audio/wav")
    delivery = %{"version" => 1, "session_id" => sub_id, "id" => Ecto.UUID.generate()}

    assert {:ok, part} =
             ResultProjection.to_part(@call_id, %{
               content: [%{type: "text", text: @spoken}],
               details: %{mediaDescriptor: descriptor, mediaDelivery: delivery}
             })

    Persistence.broadcast(session.id, "code_agent_spawned", %{
      sub_session_id: sub_id,
      prompt: "Speak"
    })

    code_event(session.id, sub_id, "tool_use", %{
      tool: @name,
      tool_use_id: @call_id,
      input: %{"text" => @text}
    })

    code_event(session.id, sub_id, "tool_result", Map.from_struct(part))
    message = Enum.find(chat(view).messages, &(&1.id == "code-agent-#{sub_id}"))
    assert [%{display: display}] = message.metadata.codeAgent.tool_calls
    assert display == SynapsisWeb.ToolResultView.present(part)

    assert [%{type: "text", text: @spoken}, %{type: "audio", mediaType: "audio/wav"}] =
             display.blocks
  end

  defp descriptor(bytes, format, mime) do
    sha = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    %{
      "uri" => "synapsis-media://audio/#{sha}.#{format}",
      "sha256" => sha,
      "byte_size" => byte_size(bytes),
      "mime_type" => mime,
      "format" => format
    }
  end

  defp chat(view) do
    render(view)
    :sys.get_state(view.pid).socket.assigns.react_chat
  end

  defp result_part(snapshot),
    do:
      snapshot.messages
      |> Enum.flat_map(&(&1.metadata[:parts] || []))
      |> Enum.find(&(&1.type == "tool_result"))

  defp stored_result(id) do
    assert {:ok, turns} = Store.list_turns(id)

    assert [result] =
             for(turn <- turns, part <- turn.parts, part[:type] == "tool_result", do: part)

    result
  end

  defp code_event(session_id, sub_id, event, payload),
    do:
      Persistence.broadcast(session_id, "code_agent_event", %{
        sub_session_id: sub_id,
        event: event,
        payload: payload
      })

  defp assert_wire_text(request) do
    blocks =
      Enum.flat_map(request["messages"], &List.wrap(&1["content"])) |> Enum.filter(&is_map/1)

    assert [result] = Enum.filter(blocks, &(&1["type"] == "tool_result"))
    assert result["tool_use_id"] == @call_id
    assert result["content"] == [%{"type" => "text", "text" => @spoken}]
    assert result["is_error"] == false
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
         %{"type" => "text_delta", "text" => "Speech received"}, "end_turn"}
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

  defp assert_audio_http(port, path, expected, format, mime) do
    assert {:ok, conn} =
             Mint.HTTP.connect(:http, "127.0.0.1", port,
               mode: :passive,
               protocols: [:http1],
               transport_opts: [timeout: 5_000]
             )

    try do
      assert {:ok, conn, ref} =
               Mint.HTTP.request(conn, "GET", path, [{"accept", mime}], nil)

      {status, headers, bytes} =
        receive_audio(conn, ref, System.monotonic_time(:millisecond) + 5_000, nil, [], [])

      assert status == 200
      assert {"content-type", mime} in headers
      assert {"content-length", Integer.to_string(byte_size(expected))} in headers
      assert {"content-disposition", "inline; filename=\"audio.#{format}\""} in headers
      assert IO.iodata_to_binary(bytes) == expected
    after
      Mint.HTTP.close(conn)
    end
  end

  defp receive_audio(conn, ref, deadline, status, headers, body) do
    remaining = deadline - System.monotonic_time(:millisecond)
    assert remaining > 0, "timed out waiting for audio delivery"
    assert {:ok, conn, responses} = Mint.HTTP.recv(conn, 0, remaining)

    {status, headers, body} =
      Enum.reduce(responses, {status, headers, body}, fn
        {:status, ^ref, value}, {_status, headers, body} -> {value, headers, body}
        {:headers, ^ref, value}, {status, headers, body} -> {status, headers ++ value, body}
        {:data, ^ref, value}, {status, headers, body} -> {status, headers, [body, value]}
        _, acc -> acc
      end)

    if {:done, ref} in responses,
      do: {status, headers, body},
      else: receive_audio(conn, ref, deadline, status, headers, body)
  end

  defp export(snapshots, bytes, format, mime) do
    if destination = System.get_env("SYNAPSIS_TOOL_RESULT_UI_EVIDENCE") do
      data =
        Map.merge(snapshots, %{
          audio: Base.encode64(bytes),
          metadata: %{
            format: format,
            mime_type: mime,
            filename: "audio.#{format}",
            sha256: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
            byte_size: byte_size(bytes)
          }
        })

      data = if format == "wav", do: Map.put(data, :wav, data.audio), else: data
      File.write!(Path.join(destination, "audio-chat-#{format}.json"), Jason.encode!(data))
      File.write!(Path.join(destination, "audio-chat.#{format}"), bytes)

      if format == "wav" do
        File.write!(Path.join(destination, "audio-chat.json"), Jason.encode!(data))
      end
    end
  end
end
