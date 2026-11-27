defmodule Synapsis.VoiceSessionTest do
  use ExUnit.Case, async: false

  alias Synapsis.{AgentConfigs, Sessions, VoiceSession}
  alias Synapsis.Agent.TestSupport.AbortableHTTP
  alias Synapsis.Provider.Registry
  alias Synapsis.Provider.TestSupport.ResponsesFixture

  @moduletag :tmp_dir
  @wait 6_000

  defmodule Wire do
    @behaviour WebSock

    def init({test, %{instance: instance, request_id: id}} = state) do
      :ok = Gaoxy.Test.Instance.establish(instance, id, self())
      send(test, {:realtime_wire, self()})
      {:ok, state}
    end

    def handle_in({payload, opcode: :text}, {test, _} = state) do
      send(test, {:client_event, JSON.decode!(payload)})
      {:ok, state}
    end

    def handle_info({:server_event, event}, state),
      do: {:push, {:text, JSON.encode!(event)}, state}

    def handle_info(:sever, state), do: {:stop, :normal, {1000, "fixture close"}, state}
    def handle_info(_, state), do: {:ok, state}
    def gaoxy_close(_, state), do: {:ok, state}

    def terminate(reason, {test, %{instance: instance, request_id: id}}) do
      Gaoxy.Test.Instance.event(instance, id, %{type: :websocket_closed, reason: reason})
      send(test, {:realtime_closed, reason})
    end
  end

  setup %{tmp_dir: dir} do
    fixture = Gaoxy.Test.open()
    test = self()
    tag = System.unique_integer([:positive])
    voice_provider = "voice-fixture-#{tag}"
    child_provider = "child-fixture-#{tag}"

    Registry.register(voice_provider, %{
      type: "openai_responses",
      api_key: "test-realtime",
      base_url: Gaoxy.Test.url(fixture)
    })

    Registry.register(child_provider, %{
      type: "openai_responses",
      api_key: "test-standard",
      base_url: Gaoxy.Test.url(fixture)
    })

    {:ok, child} =
      AgentConfigs.create(%{
        name: "standard-fixture-#{tag}",
        provider: child_provider,
        model: "ordinary-child-model",
        system_prompt: "CHILD SYSTEM FIXTURE",
        tools: [],
        tool_contract_version: 1,
        config: %{"workspace_path" => dir}
      })

    {:ok, agent} =
      AgentConfigs.create(%{
        name: "voice-fixture-#{tag}",
        kind: :voice,
        provider: voice_provider,
        voice_model: "openai/gpt-realtime",
        browser_audio_input_volume: 70,
        browser_audio_output_volume: 145,
        tools: ["spawn_agent", "interrupt_agent"],
        system_prompt: "VOICE ROOT FIXTURE",
        tool_contract_version: 1,
        voice_delegate: child.name,
        config: %{"workspace_path" => dir}
      })

    expect_connection(fixture, test)
    {:ok, session} = Sessions.create(agent.name, %{config: %{"memory_context" => false}})
    assert session.model == "openai/gpt-realtime"
    assert Sessions.voice?(session)
    refute_receive {:realtime_wire, _}, 50
    assert {:error, :voice_session_required} = Sessions.ensure_running(session.id)

    on_exit(fn ->
      Sessions.delete(session.id)
      AgentConfigs.delete(agent)
      AgentConfigs.delete(child)
      Registry.unregister(voice_provider)
      Registry.unregister(child_provider)
    end)

    %{id: session.id, fixture: fixture, child: child, agent: agent}
  end

  test "host audio requires the current Device Voice Agent and its fixed session", ctx do
    assert {:error, :invalid_audio_endpoint} = VoiceSession.start(ctx.id, mode: "host")
    refute_receive {:upgrade, _, _}, 50

    %{generation: generation} = call(ctx.id)
    assert {:error, :invalid_audio_endpoint} = VoiceSession.switch(ctx.id, mode: "host")
    hangup(ctx.id, generation)

    assert {:ok, host} = AgentConfigs.update(ctx.agent, %{kind: :host_voice})
    assert {:error, :fixed_host_session} = VoiceSession.start(ctx.id)
    assert {:error, :fixed_host_session} = Sessions.fork(ctx.id)
    assert {:ok, session} = Sessions.create(host.name)
    assert session.id == host.id

    on_exit(fn ->
      VoiceSession.delete(session.id)
      Synapsis.Session.Store.delete_session(session.id)
    end)

    assert {:error, :invalid_audio_endpoint} = VoiceSession.start(session.id, mode: "browser")
    assert {:ok, %{phase: :connecting}} = VoiceSession.start(session.id)
    assert_receive {:upgrade, _, _}, @wait
    assert_receive {:realtime_wire, _socket}, @wait
    assert_receive {:client_event, %{"type" => "session.update"}}, @wait
    assert {:error, :media_lease_in_use} = VoiceSession.start(session.id)
    assert :ok = VoiceSession.stop(session.id)
    assert :ok = VoiceSession.delete(session.id)
    assert {:ok, %{id: same_id}} = Sessions.create(host.name)
    assert same_id == session.id
  end

  test "device call outlives the caller, redials after loss, and restores mute after owner restart",
       ctx do
    {:ok, host} = AgentConfigs.update(ctx.agent, %{kind: :host_voice})
    {:ok, session} = Sessions.create(host.name)
    id = session.id

    on_exit(fn ->
      VoiceSession.stop(id)
      VoiceSession.delete(id)
      Synapsis.Session.Store.delete_session(id)
    end)

    parent = self()

    {caller, monitor} =
      spawn_monitor(fn ->
        send(parent, {:device_started, VoiceSession.start(id, input_device: "fixture-mic")})
      end)

    assert_receive {:device_started, {:ok, %{device_call: true, generation: initial}}}, @wait
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, @wait
    assert_receive {:realtime_wire, first}, @wait
    assert_receive {:client_event, %{"type" => "session.update"}}, @wait
    assert :ok = VoiceSession.mute(id, true)
    assert {:ok, %{muted: true, generation: ^initial}} = VoiceSession.status(id)

    # Keep the gateway in setup so the test never opens physical audio.
    send(first, :sever)
    assert_receive {:realtime_wire, second}, @wait
    assert_receive {:client_event, %{"type" => "session.update"}}, @wait
    assert {:ok, %{device_call: true, muted: true, generation: next}} = VoiceSession.status(id)
    assert next != initial
    [{owner, _}] = Elixir.Registry.lookup(Synapsis.Voice.Registry, id)
    Process.exit(owner, :kill)
    assert_receive {:realtime_wire, restored}, @wait
    assert_receive {:client_event, %{"type" => "session.update"}}, @wait
    assert second != restored

    assert {:ok, %{device_call: true, muted: true, endpoint: %{input_device: "fixture-mic"}}} =
             VoiceSession.status(id)

    assert :ok = VoiceSession.mute(id, false)
    assert {:ok, %{muted: false}} = VoiceSession.status(id)
    send(restored, :sever)
    assert_receive {:realtime_wire, retry}, @wait
    send(retry, :sever)

    wait_for(fn ->
      assert {:ok, %{phase: :reconnecting}} = VoiceSession.status(id)
    end)

    assert :ok = VoiceSession.stop(id)
    assert {:ok, %{phase: :offline, device_call: false}} = VoiceSession.status(id)
    refute_receive {:realtime_wire, _}, 1000
  end

  test "explicit browser selection uses its own saved devices and volumes", ctx do
    assert {:ok, _} =
             AgentConfigs.update(ctx.agent, %{
               audio_mode: "host",
               host_audio_input_device: "host-mic",
               host_audio_input_volume: 40,
               browser_audio_input_device: "browser-mic",
               browser_audio_output_device: "browser-speaker"
             })

    assert %{options: options} = call(ctx.id, mode: "browser")

    assert options == %{
             mode: "browser",
             input_device: "browser-mic",
             output_device: "browser-speaker",
             input_volume: 70,
             output_volume: 145
           }
  end

  test "one audio reference enters native history and playback-only stop preserves completion",
       ctx do
    {:ok, _} = AgentConfigs.update(ctx.agent, %{tools: ["apply_patch", "spawn_agent"]})
    %{socket: socket, generation: generation} = call(ctx.id)
    pcm = :binary.copy(<<0, 0>>, 480)

    assert :ok = VoiceSession.capture(ctx.id, generation, 1, pcm)

    assert_receive {:client_event, %{"type" => "input_audio_buffer.append", "audio" => audio}},
                   @wait

    assert Base.decode64!(audio) == pcm
    assert {:error, :invalid_voice_operation} = VoiceSession.capture(ctx.id, generation, 1, pcm)

    ut = "item_utterance"
    committed(socket, ut)
    committed(socket, ut)
    attempt = response(socket, "resp-a", ut)
    assert Enum.any?(attempt["tools"], &(&1["name"] == "spawn_agent"))
    refute Enum.any?(attempt["tools"], &(&1["name"] == "apply_patch"))

    event(socket, %{
      "type" => "response.output_audio.delta",
      "response_id" => "resp-a",
      "item_id" => "item_assistant",
      "content_index" => 0,
      "delta" => audio
    })

    assert_receive {:voice_pcm, ^generation, seq, %{item_id: "item_assistant"}, ^pcm}, @wait
    VoiceSession.playback_ack(ctx.id, generation, seq)

    done(socket, "resp-a", [assistant("item_assistant", "Completed spoken answer")])

    wait_for(fn ->
      assert [user, answer] = Sessions.get_messages(ctx.id)
      assert [%Synapsis.Part.CommittedAudio{item_id: ^ut}] = user.parts
      assert [%Synapsis.Part.SpokenAudio{text: "Completed spoken answer"}] = answer.parts
    end)

    assert :ok = VoiceSession.stop_playback(ctx.id)
    assert_receive {:voice_flush, ^generation, token, false}, @wait
    VoiceSession.flushed(ctx.id, generation, token, cursor("resp-a", "item_assistant", 13))

    assert_receive {:client_event,
                    %{
                      "type" => "conversation.item.truncate",
                      "audio_end_ms" => 13,
                      "item_id" => "item_assistant"
                    }},
                   @wait

    refute_receive {:client_event, %{"type" => "response.cancel"}}, 80
    refute_receive {:client_event, %{"type" => "response.create"}}, 80
    assert attempt["metadata"]["attempt"] != nil

    event(socket, %{
      "type" => "conversation.item.input_audio_transcription.completed",
      "item_id" => ut,
      "transcript" => "Late transcript"
    })

    wait_for(fn ->
      [user | _] = Sessions.get_messages(ctx.id)
      [audio] = user.parts

      assert Synapsis.Voice.History.transcript(ctx.id, audio.connection_generation, ut) ==
               "Late transcript"

      facts = Synapsis.Voice.History.recovery(ctx.id)
      assert facts.voice_transcript[audio.connection_generation <> ":" <> ut] == "Late transcript"

      assert %{cursor: 13, interrupted: true} =
               facts.voice_playback[audio.connection_generation <> ":item_assistant:0"]
    end)

    hangup(ctx.id, generation)
    assert_receive {:realtime_closed, _}, @wait

    restarted = call(ctx.id)
    assert restarted.generation != generation
    hangup(ctx.id, restarted.generation)
    assert_receive {:realtime_closed, _}, @wait
  end

  test "chat text and attachments share the same Realtime call and native queue as speech", ctx do
    %{socket: socket, options: options} = call(ctx.id)
    assert %{input_volume: 70, output_volume: 145} = options

    image = %Synapsis.Part.Image{media_type: "image/png", data: Base.encode64("image fixture")}
    assert :ok = VoiceSession.submit(ctx.id, "Describe this image", [image])

    assert_receive {:client_event, %{"type" => "conversation.item.create", "item" => item}},
                   @wait

    assert item["content"] == [
             %{"type" => "input_text", "text" => "Describe this image"},
             %{"type" => "input_image", "image_url" => "data:image/png;base64,#{image.data}"}
           ]

    assert %{messages: [%{id: input_id, role: "user", parts: [_, ^image]}], reply: %{text: ""}} =
             VoiceSession.chat_snapshot(ctx.id)

    assert [] = Sessions.get_messages(ctx.id)
    assert ^image = VoiceSession.chat_image(ctx.id, input_id, 0, 1)
    assert nil == VoiceSession.chat_image(ctx.id, "different-message", 0, 1)

    refute_receive {:client_event, %{"type" => "response.create"}}, 60
    acknowledge_item(socket, item["id"])
    response(socket, "resp-image", item["id"])

    event(socket, %{
      "type" => "response.output_audio_transcript.delta",
      "response_id" => "resp-image",
      "delta" => "Image answer"
    })

    wait_for(fn ->
      assert %{messages: [%{id: ^input_id}], reply: %{text: "Image answer"}} =
               VoiceSession.chat_snapshot(ctx.id)
    end)

    %{reply: %{id: answer_id}} = VoiceSession.chat_snapshot(ctx.id)
    committed(socket, "item_followup_speech")
    done(socket, "resp-image", [assistant("item_image_answer", "Image answer")])
    response(socket, "resp-speech", "item_followup_speech")
    done(socket, "resp-speech", [assistant("item_speech_answer", "Speech answer")])

    wait_for(fn ->
      assert [visual, spoken, %{id: ^answer_id}, _answer2] = Sessions.get_messages(ctx.id)
      assert visual.id == input_id
      assert [%Synapsis.Part.Text{content: "Describe this image"}, ^image] = visual.parts
      assert [%Synapsis.Part.CommittedAudio{item_id: "item_followup_speech"}] = spoken.parts

      assert %{messages: [%{id: ^input_id}, _, %{id: ^answer_id}, _], reply: nil} =
               VoiceSession.chat_snapshot(ctx.id)
    end)
  end

  test "hangup releases queued images while retaining admitted attachments", ctx do
    %{generation: generation} = call(ctx.id)
    admitted = %Synapsis.Part.Image{media_type: "image/png", data: Base.encode64("admitted")}
    discarded = %{admitted | data: Base.encode64("discarded")}

    assert :ok = VoiceSession.submit(ctx.id, "", [admitted])
    assert_receive {:client_event, %{"type" => "conversation.item.create"}}, @wait
    assert :ok = VoiceSession.submit(ctx.id, "", [discarded])
    assert %{queued: 1} = VoiceSession.chat_snapshot(ctx.id)

    hangup(ctx.id, generation)
    assert_receive {:realtime_closed, _}, @wait
    [{owner, _}] = Elixir.Registry.lookup(Synapsis.Voice.Registry, ctx.id)
    state = :sys.get_state(owner)
    assert :queue.is_empty(state.inputs)
    assert Map.values(state.image_payloads) == [admitted.data]
  end

  test "non-object Realtime errors close media without crashing the logical session", ctx do
    %{socket: socket, generation: generation} = call(ctx.id)
    [{owner, _}] = Elixir.Registry.lookup(Synapsis.Voice.Registry, ctx.id)

    event(socket, %{"type" => "error", "error" => "gateway error"})
    assert_receive {:voice_browser_close, ^generation}, @wait
    assert_receive {:realtime_closed, _}, @wait
    assert {:ok, %{phase: :error, reason: :realtime_protocol_error}} = VoiceSession.status(ctx.id)
    assert Process.alive?(owner)
  end

  test "live microphone commits appear immediately and never replay as a FIFO of replies", ctx do
    %{socket: socket} = call(ctx.id)
    committed(socket, "first")
    response(socket, "resp-first", "first")
    event(socket, %{"type" => "input_audio_buffer.speech_started", "item_id" => "live1"})

    assert_receive {:client_event, %{"type" => "response.cancel", "response_id" => "resp-first"}},
                   @wait

    items = Enum.map(1..24, &"live#{&1}")
    for item <- items, do: committed(socket, item)
    committed(socket, "live24")

    event(socket, %{
      "type" => "conversation.item.input_audio_transcription.completed",
      "item_id" => "live24",
      "transcript" => "Latest speech"
    })

    wait_for(fn ->
      assert %{queued: 0, messages: messages, facts: facts} = VoiceSession.chat_snapshot(ctx.id)
      assert Enum.map(messages, fn m -> hd(m.parts).item_id end) == ["first" | items]
      assert "Latest speech" in Map.values(facts.voice_transcript)
    end)

    done(socket, "resp-first", [])
    current = response(socket, "resp-live", "live24")
    assert Enum.map(current["input"], & &1["id"]) == ["first" | items]
    done(socket, "resp-live", [assistant("answer", "Heard you")])
    wait_for(fn -> assert length(Sessions.get_messages(ctx.id)) == 26 end)
    refute_receive {:client_event, %{"type" => "response.create"}}, 120
  end

  test "a warm call plays and finishes the current utterance before native admission returns",
       ctx do
    %{socket: socket, generation: generation} = call(ctx.id)
    committed(socket, "warm")
    response(socket, "warm-reply", "warm")
    [{owner, _}] = Elixir.Registry.lookup(Synapsis.Voice.Registry, ctx.id)
    adapter = :sys.get_state(owner).adapter
    :sys.suspend(adapter)

    try do
      done(socket, "warm-reply", [assistant("warm-answer", "Ready")])
      committed(socket, "live")
      response(socket, "live-reply", "live")

      event(socket, %{
        "type" => "response.output_audio.delta",
        "response_id" => "live-reply",
        "item_id" => "live-answer",
        "content_index" => 0,
        "delta" => Base.encode64(<<0, 0>>)
      })

      assert_receive {:voice_pcm, ^generation, _, %{item_id: "live-answer"}, _}, @wait
      done(socket, "live-reply", [assistant("live-answer", "On time")])
    after
      :sys.resume(adapter)
    end

    wait_for(fn ->
      assert [%{role: "user"}, %{role: "assistant"}, %{role: "user"}, answer] =
               Sessions.get_messages(ctx.id)

      assert [%Synapsis.Part.SpokenAudio{text: "On time"}] = answer.parts
    end)

    refute_receive {:client_event, %{"type" => "response.create"}}, 100
  end

  test "VAD prepares the native response during speech and dispatches on commit", ctx do
    %{socket: socket} = call(ctx.id)
    event(socket, %{"type" => "input_audio_buffer.speech_started", "item_id" => "speaking"})
    wait_for(fn -> assert {:ok, %{phase: :responding}} = VoiceSession.status(ctx.id) end)
    assert %{messages: []} = VoiceSession.chat_snapshot(ctx.id)
    refute_receive {:client_event, %{"type" => "response.create"}}, 60
    committed(socket, "speaking")
    response(socket, "now", "speaking")
    done(socket, "now", [assistant("response", "Hello")])

    wait_for(fn ->
      assert [%{role: "user"}, %{role: "assistant"}] = Sessions.get_messages(ctx.id)
    end)
  end

  test "speech during history sync retires the unsent reply and accepts the next input", ctx do
    %{socket: socket, generation: generation} = call(ctx.id)
    assert :ok = VoiceSession.submit(ctx.id, "First question", [])

    assert_receive {:client_event, %{"type" => "conversation.item.create", "item" => prior}},
                   @wait

    event(socket, %{"type" => "input_audio_buffer.speech_started"})
    committed(socket, "item_second")
    acknowledge_item(socket, prior["id"])
    response(socket, "reply-second", "item_second")
    done(socket, "reply-second", [assistant("answer-second", "Still here")])

    wait_for(fn ->
      assert {:ok, %{phase: :listening, generation: ^generation}} = VoiceSession.status(ctx.id)

      assert [%{role: "user"}, %{role: "user"}, %{role: "assistant"}] =
               Sessions.get_messages(ctx.id)
    end)
  end

  test "a failed provider reply leaves the same connection ready for a new utterance", ctx do
    %{socket: socket, generation: generation} = call(ctx.id)
    committed(socket, "item_failed")
    response(socket, "reply-failed", "item_failed")

    event(socket, %{
      "type" => "response.output_audio.delta",
      "response_id" => "reply-failed",
      "item_id" => "partial-answer",
      "content_index" => 0,
      "delta" => Base.encode64(<<0, 0>>)
    })

    assert_receive {:voice_pcm, ^generation, _, %{item_id: "partial-answer"}, _}, @wait

    event(socket, %{
      "type" => "response.done",
      "response" => %{
        "id" => "reply-failed",
        "status" => "failed",
        "status_details" => %{
          "type" => "failed",
          "error" => %{"type" => "server_error", "code" => nil}
        }
      }
    })

    wait_for(fn ->
      assert {:ok,
              %{phase: :listening, reason: :realtime_response_failed, generation: ^generation}} =
               VoiceSession.status(ctx.id)
    end)

    assert_receive {:voice_flush, ^generation, token, false}, @wait
    VoiceSession.flushed(ctx.id, generation, token, nil)

    assert_receive {:client_event,
                    %{"type" => "conversation.item.truncate", "item_id" => "partial-answer"}},
                   @wait

    committed(socket, "item_next")
    response(socket, "reply-next", "item_next")
    done(socket, "reply-next", [assistant("answer-next", "Back online")])

    wait_for(fn ->
      assert [%{role: "user"}, %{role: "user"}, %{role: "assistant"}] =
               Sessions.get_messages(ctx.id)

      assert {:ok, %{phase: :listening, reason: nil, generation: ^generation}} =
               VoiceSession.status(ctx.id)
    end)
  end

  test "active barge-in cancels only its response and ignores late output", ctx do
    %{socket: socket, generation: generation} = call(ctx.id)
    committed(socket, "item_first")
    response(socket, "resp-old", "item_first")

    event(socket, %{"type" => "input_audio_buffer.speech_started"})

    assert_receive {:client_event, %{"type" => "response.cancel", "response_id" => "resp-old"}},
                   @wait

    committed(socket, "item_second")

    event(socket, %{
      "type" => "response.done",
      "response" => %{
        "id" => "resp-old",
        "status" => "cancelled",
        "output" => [
          function("call_cancelled", %{"task_name" => "should-not-run", "message" => "ignore"})
        ]
      }
    })

    response(socket, "resp-next", "item_second")

    event(socket, %{
      "type" => "response.output_audio.delta",
      "response_id" => "resp-old",
      "item_id" => "item_late",
      "content_index" => 0,
      "delta" => Base.encode64(<<0, 0>>)
    })

    refute_receive {:voice_pcm, ^generation, _, %{item_id: "item_late"}, _}, 100
    done(socket, "resp-next", [assistant("item_final", "Second response")])
    wait_for(fn -> assert length(Sessions.get_messages(ctx.id)) == 3 end)
    assert {:ok, %{tasks: []}} = VoiceSession.status(ctx.id)
  end

  test "a malformed tool response leaves the same call available for the next turn", ctx do
    %{socket: socket, generation: generation} = call(ctx.id)
    committed(socket, "item_tool_request")
    response(socket, "reply-with-bad-tool", "item_tool_request")

    valid = function("call_valid", %{"task_name" => "untrusted-batch", "message" => "Ignore"})
    malformed = %{function("call_invalid", %{}) | "arguments" => ~s(["not an object"])}
    done(socket, "reply-with-bad-tool", [valid, malformed])

    wait_for(fn ->
      assert {:ok, %{phase: :listening, generation: ^generation, reason: :invalid_function_call}} =
               VoiceSession.status(ctx.id)

      assert %{busy: false, reply: nil} = VoiceSession.chat_snapshot(ctx.id)
    end)

    refute_receive {:realtime_closed, _}, 60
    refute_receive {:client_event, %{"type" => "response.create"}}, 60
    assert {:ok, %{tasks: []}} = VoiceSession.status(ctx.id)

    committed(socket, "item_next_question")
    next = response(socket, "reply-next", "item_next_question")
    refute Enum.any?(next["input"], &(&1["id"] in ["item_call_valid", "item_call_invalid"]))
    assert {:ok, %{phase: :responding, reason: nil}} = VoiceSession.status(ctx.id)
    done(socket, "reply-next", [assistant("item_next_answer", "Still connected")])

    wait_for(fn ->
      assert [%{role: "user"}, %{role: "user"}, %{role: "assistant"}] =
               Sessions.get_messages(ctx.id)
    end)
  end

  test "a journaled provider-only interruption lets the same voice session reopen after restart",
       ctx do
    %{socket: socket} = call(ctx.id)
    committed(socket, "item_interrupted")
    response(socket, "reply-interrupted", "item_interrupted")
    send(socket, :sever)

    wait_for(fn ->
      assert %{busy: false, phase: :error} = VoiceSession.chat_snapshot(ctx.id)
      assert [%{role: "user"}] = Sessions.get_messages(ctx.id)
    end)

    assert :ok = VoiceSession.delete(ctx.id)

    wait_for(fn ->
      assert {:ok, %{root: %{status: :unknown_outcome}}} =
               Synapsis.Runtime.Store.get_projection(ctx.id)
    end)

    %{socket: reopened} = call(ctx.id)
    committed(reopened, "item_new")
    response(reopened, "reply-reopened", "item_new")
    done(reopened, "reply-reopened", [assistant("item_answer", "Same session")])

    wait_for(fn ->
      assert [%{role: "user"}, %{role: "user"}, %{role: "assistant"}] =
               Sessions.get_messages(ctx.id)
    end)
  end

  test "standard child retains its own model and delivers the result after media hangup", ctx do
    test = self()

    Gaoxy.Test.expect_once(ctx.fixture, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:child_request, JSON.decode!(body), self()})

      receive do
        :finish_child -> :ok
      after
        15_000 -> raise "child fixture timed out"
      end

      events = [ResponsesFixture.text_delta("STANDARD CHILD DONE"), ResponsesFixture.completed()]

      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      {:ok, conn} =
        Plug.Conn.chunk(conn, Enum.map(events, &("data: " <> JSON.encode!(&1) <> "\n\n")))

      conn
    end)

    %{socket: socket, generation: generation} = call(ctx.id)
    committed(socket, "item_delegate")
    response(socket, "resp-spawn", "item_delegate")

    spawn =
      function("call_spawn", %{
        "task_name" => "work",
        "message" => "Report the fixture",
        "agent_type" => ctx.child.name
      })

    done(socket, "resp-spawn", [spawn, spawn])
    assert_receive {:child_request, request, child_handler}, @wait
    assert request["model"] == "ordinary-child-model"
    assert request["instructions"] =~ "CHILD SYSTEM FIXTURE"
    assert inspect(request["input"]) =~ "Report the fixture"
    refute inspect(request["input"]) =~ "item_delegate"

    assert_receive {:client_event,
                    %{
                      "type" => "conversation.item.create",
                      "item" => %{
                        "id" => output,
                        "type" => "function_call_output",
                        "call_id" => "call_spawn"
                      }
                    }},
                   @wait

    acknowledge_item(socket, output)
    response(socket, "resp-continuation", output)
    done(socket, "resp-continuation", [assistant("item_waiting", "Working on it")])

    wait_for(fn ->
      assert Enum.any?(
               Sessions.get_messages(ctx.id),
               &match?([%Synapsis.Part.SpokenAudio{text: "Working on it"}], &1.parts)
             )
    end)

    committed(socket, "item_while_child_runs")
    response(socket, "resp-concurrent", "item_while_child_runs")
    done(socket, "resp-concurrent", [assistant("item_concurrent", "Still here")])

    hangup(ctx.id, generation)
    assert_receive {:realtime_closed, _}, @wait
    send(child_handler, :finish_child)

    wait_for(fn ->
      assert {:ok,
              %{
                phase: :offline,
                tasks: [
                  %{
                    status: :completed,
                    result_delivery: %{status: :accepted},
                    final: "STANDARD CHILD DONE"
                  }
                ]
              }} = VoiceSession.status(ctx.id)
    end)

    refute_receive {:realtime_wire, _}, 100

    %{socket: reopened} = call(ctx.id)
    committed(reopened, "item_reopen")

    assert_receive {:client_event,
                    %{
                      "type" => "conversation.item.create",
                      "item" => %{
                        "id" => result,
                        "content" => [%{"text" => text}]
                      }
                    }},
                   @wait

    assert text =~ "STANDARD CHILD DONE"
    acknowledge_item(reopened, result)
    response(reopened, "resp-result", result)
    done(reopened, "resp-result", [assistant("item_result", "Result delivered")])
  end

  test "controller loss fences capture and disconnects Realtime without replay", ctx do
    owner = self()

    controller =
      spawn(fn ->
        send(owner, {:started, VoiceSession.start(ctx.id)})

        receive do
          :stop_controller -> :ok
        end
      end)

    assert_receive {:started, {:ok, %{generation: old}}}, @wait
    assert_receive {:realtime_wire, _}, @wait
    assert_receive {:client_event, %{"type" => "session.update"}}, @wait
    assert {:error, :media_lease_in_use} = VoiceSession.start(ctx.id)
    send(controller, :stop_controller)
    assert_receive {:realtime_closed, _}, @wait
    assert {:ok, %{phase: :error, reason: :media_owner_lost}} = VoiceSession.status(ctx.id)
    %{generation: next, socket: socket} = call(ctx.id)
    assert old != next
    assert {:error, :invalid_voice_operation} = VoiceSession.capture(ctx.id, old, 1, <<0, 0>>)
    refute_receive {:client_event, %{"type" => "input_audio_buffer.append"}}, 100
    send(socket, :sever)

    wait_for(fn ->
      assert {:ok, %{phase: :error, reason: :realtime_disconnected}} = VoiceSession.status(ctx.id)
    end)
  end

  test "a lost Realtime reply can resume in the same session without replaying the turn", ctx do
    %{socket: socket, generation: original} = call(ctx.id)
    committed(socket, "item_lost")
    first = response(socket, "reply-lost", "item_lost")

    event(socket, %{
      "type" => "conversation.item.input_audio_transcription.completed",
      "item_id" => "item_lost",
      "transcript" => "Prior question"
    })

    send(socket, :sever)

    wait_for(fn ->
      assert {:ok, %{phase: :error, reason: :realtime_disconnected}} = VoiceSession.status(ctx.id)
      assert %{busy: false, reply: nil} = VoiceSession.chat_snapshot(ctx.id)
      assert [%{role: "user"}] = Sessions.get_messages(ctx.id)
    end)

    %{socket: next_socket, generation: next} = call(ctx.id)
    assert original != next
    refute_receive {:client_event, %{"type" => "response.create"}}, 100

    assert {:error, :invalid_voice_operation} =
             VoiceSession.capture(ctx.id, original, 1, <<0, 0>>)

    committed(next_socket, "item_new")

    assert_receive {:client_event, %{"type" => "conversation.item.create", "item" => prior}},
                   @wait

    assert [%{"type" => "input_text", "text" => "[Prior microphone transcript] Prior question"}] =
             prior["content"]

    acknowledge_item(next_socket, prior["id"])
    second = response(next_socket, "reply-new", "item_new")
    assert first["metadata"]["attempt"] != second["metadata"]["attempt"]
    refute %{"type" => "item_reference", "id" => "item_lost"} in second["input"]
    done(next_socket, "reply-new", [assistant("answer-new", "Back online")])

    wait_for(fn ->
      assert [%{role: "user"}, %{role: "user"}, %{role: "assistant"}] =
               Sessions.get_messages(ctx.id)
    end)
  end

  test "redial after owner loss abandons a provider-only audio attempt in the same session",
       ctx do
    archived = %Synapsis.Part.CommittedAudio{item_id: "archived", connection_generation: "past"}
    assert {:ok, _} = Synapsis.Message.append(ctx.id, %{role: "user", parts: [archived]})
    old = record_orphaned_audio_attempt(ctx.id)
    history = Sessions.get_messages(ctx.id)

    %{socket: next} = call(ctx.id)
    refute_receive {:client_event, %{"type" => "response.create"}}, 100
    assert Sessions.get_messages(ctx.id) == history

    committed(next, "item_next")
    fresh = response(next, "reply-next", "item_next")
    assert old["metadata"]["attempt"] != fresh["metadata"]["attempt"]
    refute %{"type" => "item_reference", "id" => "item_orphan"} in fresh["input"]
    done(next, "reply-next", [assistant("answer-next", "Back online")])

    wait_for(fn ->
      {previous, new} = Enum.split(Sessions.get_messages(ctx.id), length(history))
      assert previous == history
      assert [%{role: "user"}, %{role: "assistant"}] = new
    end)
  end

  test "owner loss after outbox acknowledgement admits fresh audio without replay", ctx do
    record_orphaned_audio_attempt(ctx.id, &%{&1 | outbox: []})
    %{socket: next} = call(ctx.id)
    refute_receive {:client_event, %{"type" => "response.create"}}, 100

    committed(next, "new-audio")
    response(next, "new-reply", "new-audio")
    done(next, "new-reply", [assistant("new-answer", "Heard you")])

    wait_for(fn ->
      assert [old, fresh, %{role: "assistant"}] = Sessions.get_messages(ctx.id)
      assert [%Synapsis.Part.CommittedAudio{item_id: "item_orphan"}] = old.parts
      assert [%Synapsis.Part.CommittedAudio{item_id: "new-audio"}] = fresh.parts
    end)
  end

  test "a provider outbox belonging to a different attempt still requires recovery", ctx do
    record_orphaned_audio_attempt(ctx.id, fn aggregate ->
      [intent] = aggregate.outbox
      %{aggregate | outbox: [put_in(intent.operation.attempt_id, "another_attempt")]}
    end)

    VoiceSession.start(ctx.id)

    wait_for(fn ->
      assert {:ok, %{phase: :error, reason: :voice_runtime_requires_recovery}} =
               VoiceSession.status(ctx.id)
    end)

    refute_receive {:client_event, %{"type" => "response.create"}}, 100
  end

  test "an unresponsive Realtime reply ends before the Conversation deadline and permits reconnect",
       ctx do
    key = :voice_response_idle_timeout
    saved = Application.fetch_env(:synapsis_agent, key)
    Application.put_env(:synapsis_agent, key, 500)

    on_exit(fn ->
      case saved do
        {:ok, value} -> Application.put_env(:synapsis_agent, key, value)
        :error -> Application.delete_env(:synapsis_agent, key)
      end
    end)

    %{socket: socket} = call(ctx.id)
    committed(socket, "item_stalled")
    response(socket, "reply-stalled", "item_stalled")

    wait_for(fn ->
      assert {:ok, %{phase: :error, reason: :realtime_response_timeout}} =
               VoiceSession.status(ctx.id)

      assert %{busy: false, reply: nil} = VoiceSession.chat_snapshot(ctx.id)
    end)

    %{socket: reopened} = call(ctx.id)
    committed(reopened, "item_new")
    response(reopened, "reply-new", "item_new")
    done(reopened, "reply-new", [assistant("answer-new", "Back online")])

    wait_for(fn ->
      assert [%{role: "user"}, %{role: "user"}, %{role: "assistant"}] =
               Sessions.get_messages(ctx.id)
    end)
  end

  test "a recovery-required voice session can continue from a copy of its saved history", ctx do
    journal = Synapsis.Runtime.Store
    root = %{status: :unknown_outcome, run_id: "unsettled"}

    assert :ok =
             journal.put_projection(ctx.id, %{root: root, agents: [], recovery_required: true})

    audio = %Synapsis.Part.CommittedAudio{item_id: "item_prior", connection_generation: "old"}
    assert {:ok, _} = Synapsis.Message.append(ctx.id, %{role: "user", parts: [audio]})
    assert :ok = journal.put_fact(ctx.id, :voice_transcript, "old:item_prior", "Saved speech")

    spoken = %Synapsis.Part.SpokenAudio{
      item_id: "item_played",
      response_id: "reply-old",
      content_index: 0,
      connection_generation: "old",
      text: "Saved reply"
    }

    assert {:ok, _} = Synapsis.Message.append(ctx.id, %{role: "assistant", parts: [spoken]})
    playback = %{generated: true, interrupted: false}
    assert :ok = journal.put_fact(ctx.id, :voice_playback, "old:item_played:0", playback)

    assert :ok =
             journal.put_fact(ctx.id, :voice_transcript, "old:unadmitted", "Skipped speech")

    case VoiceSession.start(ctx.id) do
      {:ok, %{phase: :connecting}} ->
        receive do
          {:realtime_wire, socket} -> event(socket, %{"type" => "session.updated"})
        after
          100 -> :ok
        end

      {:error, :voice_runtime_requires_recovery} ->
        :ok
    end

    wait_for(fn ->
      assert {:ok, %{phase: :error, reason: :voice_runtime_requires_recovery}} =
               VoiceSession.status(ctx.id)
    end)

    refute_receive {:voice_browser_open, _, _}, 100
    flush_wire_messages()

    assert {:ok, branch} = Sessions.fork(ctx.id)
    on_exit(fn -> Sessions.delete(branch.id) end)

    assert {:ok, %{"old:item_prior" => "Saved speech"}} =
             journal.list_facts_by_identity(branch.id, :voice_transcript)

    assert {:ok, %{"old:item_played:0" => ^playback}} =
             journal.list_facts_by_identity(branch.id, :voice_playback)

    assert :not_found = journal.get_projection(branch.id)
    assert {:ok, %{root: ^root}} = journal.get_projection(ctx.id)

    %{socket: next} = call(branch.id)
    committed(next, "item_next")

    assert_receive {:client_event, %{"type" => "conversation.item.create", "item" => prior}},
                   @wait

    assert [%{"text" => "[Prior microphone transcript] Saved speech"}] = prior["content"]
    acknowledge_item(next, prior["id"])

    assert_receive {:client_event,
                    %{"type" => "conversation.item.create", "item" => prior_reply}},
                   @wait

    assert [%{"text" => "[Prior assistant speech played to the user] Saved reply"}] =
             prior_reply["content"]

    acknowledge_item(next, prior_reply["id"])
    response(next, "reply-new", "item_next")
    done(next, "reply-new", [assistant("answer-new", "Continued")])

    wait_for(fn ->
      assert [%{role: "user"}, %{role: "assistant"}, %{role: "user"}, %{role: "assistant"}] =
               Sessions.get_messages(branch.id)
    end)
  end

  test "cancel is scoped to the observed child run and keeps media available", ctx do
    test = self()

    Gaoxy.Test.stub(ctx.fixture, "POST", "/v1/responses", fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)

      conn =
        conn
        |> Gaoxy.HTTP.put_stream_timeout(6_000)
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      send(test, {:cancel_fixture_child_started, self()})

      case AbortableHTTP.await(conn, :fixture_teardown, 5_000, test) do
        {:disconnected, conn} -> conn
        {:released, conn} -> conn
        {:timeout, _} -> raise "child stream was not retired"
      end
    end)

    %{socket: socket} = call(ctx.id)
    committed(socket, "item_child")
    response(socket, "resp-child", "item_child")

    done(socket, "resp-child", [
      function("call_child", %{"task_name" => "cancel", "message" => "Work until cancelled"})
    ])

    assert_receive {:cancel_fixture_child_started, fixture_handler}, @wait
    fixture_ref = Process.monitor(fixture_handler)

    assert {:ok, %{tasks: [%{agent_id: agent, run_id: run, status: :running}]}} =
             VoiceSession.status(ctx.id)

    assert {:error, :task_not_running} = VoiceSession.cancel_task(ctx.id, agent, "stale-run")
    assert :ok = VoiceSession.cancel_task(ctx.id, agent, run)
    assert {:error, :task_not_running} = VoiceSession.cancel_task(ctx.id, agent, run)

    wait_for(fn ->
      assert {:ok, %{phase: phase, tasks: [%{status: status}]}} = VoiceSession.status(ctx.id)
      assert phase in [:listening, :responding]
      assert status in [:closed, :interrupted]
    end)

    refute_receive {:client_event, %{"type" => "response.cancel"}}, 100
    assert_receive {:DOWN, ^fixture_ref, :process, ^fixture_handler, _}, @wait
  end

  test "device switching waits for release and rejects old-generation frames", ctx do
    %{generation: original} = call(ctx.id)

    {:ok, scope} = Synapsis.SkillWorkshop.capture(ctx.agent.id)
    File.mkdir_p!(Path.dirname(scope.root))
    File.write!(scope.root, "unavailable workshop directory")
    on_exit(fn -> File.rm(scope.root) end)
    assert {:error, _} = Synapsis.Agent.Resolver.resolve_configured(ctx.agent.name)

    assert {:ok, _} = AgentConfigs.update(ctx.agent, %{browser_audio_output_volume: 120})
    assert :ok = VoiceSession.switch(ctx.id, mode: "browser", input_device: "new-device")
    assert_receive {:voice_flush, ^original, token, true}, @wait
    refute_receive {:voice_browser_open, _, _}, 80
    VoiceSession.flushed(ctx.id, original, token, nil)

    assert_receive {:voice_browser_open, generation,
                    %{input_device: "new-device", output_volume: 120}},
                   @wait

    assert generation != original
    assert :ok = VoiceSession.browser_ready(ctx.id, generation, %{})

    assert {:error, :invalid_voice_operation} =
             VoiceSession.capture(ctx.id, original, 1, <<0, 0>>)

    assert :ok = VoiceSession.capture(ctx.id, generation, 1, <<0, 0>>)
  end

  # Restore the last durable checkpoint before the old owner could run its
  # shutdown callbacks, as after a VM exit in the middle of response.create.
  defp record_orphaned_audio_attempt(id, change \\ &Function.identity/1) do
    journal = Synapsis.Runtime.Store
    %{socket: socket} = call(id)
    committed(socket, "item_orphan")
    response = response(socket, "reply-orphan", "item_orphan")

    {:ok, %{entries: [%{locator: loc, aggregate: checkpoint}]}} =
      Synapsis.Agent.Runtime.RunInventory.load(id)

    {:ok, projection} = journal.get_projection(id)
    [{owner, _}] = Elixir.Registry.lookup(Synapsis.Voice.Registry, id)
    adapter = :sys.get_state(owner).adapter
    ref = Process.monitor(adapter)
    assert :ok = VoiceSession.delete(id)
    assert_receive {:DOWN, ^ref, :process, ^adapter, _}, @wait
    {:ok, latest} = journal.load(loc.namespace, loc.run_id)
    checkpoint = %{change.(checkpoint) | revision: latest.revision + 1}

    assert :ok =
             journal.commit(
               loc.namespace,
               loc.run_id,
               latest.revision,
               loc.incarnation,
               checkpoint
             )

    assert :ok = journal.put_projection(id, put_in(projection.root.status, :unknown_outcome))
    flush_wire_messages()
    response
  end

  defp hangup(id, generation) do
    assert :ok = VoiceSession.stop(id)
    assert_receive {:voice_flush, ^generation, token, true}, @wait
    VoiceSession.flushed(id, generation, token, nil)
  end

  defp flush_wire_messages do
    receive do
      {:upgrade, _, _} -> flush_wire_messages()
      {:realtime_wire, _} -> flush_wire_messages()
      {:realtime_closed, _} -> flush_wire_messages()
      {:client_event, _} -> flush_wire_messages()
    after
      0 -> :ok
    end
  end

  defp expect_connection(fixture, test) do
    Gaoxy.Test.stub(fixture, "GET", "/v1/realtime", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      send(
        test,
        {:upgrade, conn.query_params["model"], Plug.Conn.get_req_header(conn, "authorization")}
      )

      WebSockAdapter.upgrade(conn, Wire, {test, conn.private.gaoxy_test}, timeout: 60_000)
    end)
  end

  defp call(id, endpoint_options \\ []) do
    assert {:ok, %{phase: :connecting}} = VoiceSession.start(id, endpoint_options)
    assert_receive {:upgrade, "openai/gpt-realtime", ["Bearer test-realtime"]}, @wait
    assert_receive {:realtime_wire, socket}, @wait
    assert_receive {:client_event, %{"type" => "session.update", "session" => settings}}, @wait
    assert get_in(settings, ["audio", "input", "turn_detection", "create_response"]) == false
    event(socket, %{"type" => "session.updated"})
    assert_receive {:voice_browser_open, generation, options}, @wait
    assert :ok = VoiceSession.browser_ready(id, generation, %{"echo_cancellation" => true})
    %{socket: socket, generation: generation, options: options}
  end

  defp event(socket, data), do: send(socket, {:server_event, data})

  defp committed(socket, id),
    do: event(socket, %{"type" => "input_audio_buffer.committed", "item_id" => id})

  defp acknowledge_item(socket, id),
    do: event(socket, %{"type" => "conversation.item.added", "item" => %{"id" => id}})

  defp response(socket, id, item) do
    assert_receive {:client_event, %{"type" => "response.create", "response" => response}}, @wait
    assert %{"type" => "item_reference", "id" => item} in response["input"]

    event(socket, %{
      "type" => "response.created",
      "response" => %{"id" => id, "metadata" => response["metadata"]}
    })

    response
  end

  defp done(socket, id, output) do
    event(socket, %{
      "type" => "response.done",
      "response" => %{
        "id" => id,
        "status" => "completed",
        "output" => output,
        "usage" => %{"input_tokens" => 10, "output_tokens" => 3}
      }
    })
  end

  defp assistant(id, transcript),
    do: %{
      "id" => id,
      "type" => "message",
      "role" => "assistant",
      "status" => "completed",
      "content" => [%{"type" => "output_audio", "transcript" => transcript}]
    }

  defp function(id, arguments),
    do: %{
      "id" => "item_" <> id,
      "call_id" => id,
      "name" => "spawn_agent",
      "type" => "function_call",
      "arguments" => JSON.encode!(arguments),
      "status" => "completed"
    }

  defp cursor(response, item, ms),
    do: %{
      "response_id" => response,
      "item_id" => item,
      "content_index" => 0,
      "audio_end_ms" => ms,
      "accurate" => true
    }

  defp wait_for(assertion, count \\ 120)
  defp wait_for(assertion, 0), do: assertion.()

  defp wait_for(assertion, count) do
    assertion.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(30)
      wait_for(assertion, count - 1)
  end
end
