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

    %{id: session.id, fixture: fixture, child: child}
  end

  test "one audio reference enters native history and playback-only stop preserves completion",
       ctx do
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
    end)

    hangup(ctx.id, generation)
    assert_receive {:realtime_closed, _}, @wait
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

  test "cancel is scoped to the observed child run and keeps media available", ctx do
    test = self()

    Gaoxy.Test.stub(ctx.fixture, "POST", "/v1/responses", fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
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
    assert :ok = VoiceSession.switch(ctx.id, mode: "browser", input_device: "new-device")
    assert_receive {:voice_flush, ^original, token, true}, @wait
    refute_receive {:voice_browser_open, _, _}, 80
    VoiceSession.flushed(ctx.id, original, token, nil)
    assert_receive {:voice_browser_open, generation, %{input_device: "new-device"}}, @wait
    assert generation != original
    assert :ok = VoiceSession.browser_ready(ctx.id, generation, %{})

    assert {:error, :invalid_voice_operation} =
             VoiceSession.capture(ctx.id, original, 1, <<0, 0>>)

    assert :ok = VoiceSession.capture(ctx.id, generation, 1, <<0, 0>>)
  end

  defp hangup(id, generation) do
    assert :ok = VoiceSession.stop(id)
    assert_receive {:voice_flush, ^generation, token, true}, @wait
    VoiceSession.flushed(id, generation, token, nil)
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

  defp call(id) do
    assert {:ok, %{phase: :connecting}} = VoiceSession.start(id)
    assert_receive {:upgrade, "openai/gpt-realtime", ["Bearer test-realtime"]}, @wait
    assert_receive {:realtime_wire, socket}, @wait
    assert_receive {:client_event, %{"type" => "session.update", "session" => settings}}, @wait
    assert get_in(settings, ["audio", "input", "turn_detection", "create_response"]) == false
    event(socket, %{"type" => "session.updated"})
    assert_receive {:voice_browser_open, generation, _}, @wait
    assert :ok = VoiceSession.browser_ready(id, generation, %{"echo_cancellation" => true})
    %{socket: socket, generation: generation}
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
