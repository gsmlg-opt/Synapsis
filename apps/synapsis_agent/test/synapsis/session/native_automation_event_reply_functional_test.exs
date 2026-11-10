defmodule Synapsis.Session.NativeAutomationEventReplyFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  import Synapsis.Agent.DaemonCase, only: [wait_for: 1]

  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Agent.Tools.AutomationWake
  alias Synapsis.Part.{Text, ToolResult}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, PendingInputStore, Store, Worker}
  alias Synapsis.Sessions

  @moduletag :tmp_dir
  @wake "synapsis::automations_wake"
  @prompt "Accept the event reply fixture"
  @notice "Render this accepted manual event"
  @replay "Recall raw event reply history"
  @event_text "HEARTBEAT_OK Event ready🙂🙂"
  @effect_id "event-reply-effect"

  test "native wake presents split event responses after raw-preserving canonical and transcript commits",
       ctx do
    h = fixture(ctx.tmp_dir, [@wake, "exec_command"])
    install_event_provider(h)
    id = h.session.id
    assert :ok = Worker.send_message(id, @prompt)
    assert_receive {:caller_accepted, request, caller}, 10_000
    assert names(request) == Enum.sort([@wake, "exec_command"])
    native_caller = runtime(id)
    catalog = :sys.get_state(native_caller.root).catalog
    assert catalog.registry.tools[@wake].backend == AutomationWake

    result =
      Enum.find(
        Backplane.AgentRuntime.Conversation.status(native_caller.root).messages,
        &(&1.role == :tool and &1[:tool_call_id] == "event-reply-wake")
      )

    assert result.result.structured == %{"ok" => true}
    assert {:ok, [accepted]} = PendingInputStore.list_result(id)
    assert accepted.event["phase"] == "staged"
    assert accepted.content == @notice
    assert accepted.input_provenance == provenance(h)
    {_pid, caller_state} = worker_state(id)
    assert caller_state.runtime_active
    assert File.read(effect_path(h)) == {:error, :enoent}
    send(caller, :release_event_reply)

    assert_receive {:event_prefix_sent, event_request, event_handler}, 10_000
    assert List.last(user_texts(event_request)) == @notice
    prefix = delta("HEARTBEAT_")
    view = Map.fetch!(prefix, :reply_presentation)
    assert view.phase == "preview"
    assert view.text == "HEARTBEAT_"
    assert view.occurrence_id == accepted.id
    assert view.session_id == id
    assert is_binary(view.run_id)

    assert view.responses == [
             %{
               response_index: 0,
               text: "HEARTBEAT_",
               hidden: false,
               text_parts: [%{index: 0, text: "HEARTBEAT_"}]
             }
           ]

    snapshot = Worker.snapshot(id)
    assert snapshot.in_flight_text == "HEARTBEAT_"
    assert snapshot.reply_presentation == Map.put(view, :committed_messages, [])
    assert {:ok, staged_turns} = Store.list_turns(id)
    event_input = Enum.find(staged_turns, &(&1.id == accepted.id))
    assert event_input.parts == [%{type: "text", text: @notice}]
    assert event_input.internal_turn_source == "event"
    assert event_input.input_provenance == provenance(h)

    send(event_handler, :release_event_reply)
    assert_receive {:event_marker_sent, ^event_handler}, 10_000
    marker = Map.fetch!(delta("OK"), :reply_presentation)
    assert marker.phase == "preview"
    assert marker.text == ""
    assert marker.hidden
    assert marker.revision > view.revision
    assert Worker.snapshot(id).in_flight_text == "HEARTBEAT_OK"
    send(event_handler, :release_event_reply)

    assert_receive {:event_text_sent, ^event_handler}, 10_000
    meaningful = Map.fetch!(delta(" Event ready🙂🙂"), :reply_presentation)
    assert meaningful.text == "Event ready🙂🙂"
    assert not meaningful.hidden
    assert meaningful.revision > marker.revision
    assert Worker.snapshot(id).in_flight_text == @event_text
    send(event_handler, :release_event_reply)

    assert_receive {:effect_following, following, final_handler}, 10_000
    assert File.read!(effect_path(h)) == "effect\n"
    canonical = presentation("response")
    assert canonical.text == "Event ready🙂🙂"

    assert [
             %{
               response_index: 0,
               text: "Event ready🙂🙂",
               hidden: false,
               text_parts: [%{index: 0, text: "Event ready🙂🙂"}]
             }
           ] = canonical.responses

    assert canonical.revision > meaningful.revision
    assert Worker.snapshot(id).reply_presentation.text == "Event ready🙂🙂"
    assert Worker.snapshot(id).in_flight_text == @event_text
    effect_result = Enum.find(following["messages"], &(&1["tool_call_id"] == @effect_id))
    assert content(effect_result["content"]) =~ "HEARTBEAT_OK"
    native_event = runtime(id)
    native_messages = Backplane.AgentRuntime.Conversation.status(native_event.root).messages

    assert Enum.any?(
             native_messages,
             &(&1.role == :assistant and text(&1.content) == @event_text)
           )

    send(final_handler, :release_event_reply)

    assert_receive {:event_terminal_sent, ^final_handler}, 10_000
    final = Map.fetch!(delta("HEARTBEAT_OK"), :reply_presentation)
    assert final.text == "Event ready🙂🙂"
    assert Enum.at(final.responses, 1).hidden
    assert Worker.snapshot(id).in_flight_text == @event_text <> "HEARTBEAT_OK"
    send(final_handler, :release_event_reply)

    canonical_final = presentation("response")
    assert canonical_final.text == "Event ready🙂🙂"
    assert length(canonical_final.responses) == 2
    assert Enum.at(canonical_final.responses, 1).hidden
    first_committed = presentation("committed")
    assert first_committed.text == "Event ready🙂🙂"
    assert first_committed.response_index == 0
    assert not first_committed.hidden
    assert {:ok, acknowledged_turns} = Store.list_turns(id)
    at_ack = Enum.find(acknowledged_turns, &(&1.id == first_committed.message_id))
    assert at_ack.id == first_committed.message_id
    assert at_ack.parts |> Enum.find(&(&1.type == "text")) |> Map.fetch!(:text) == @event_text
    second_committed = presentation("committed")
    assert second_committed.hidden
    assert second_committed.text == ""
    assert second_committed.response_index == 1
    assert first_committed.message_id != second_committed.message_id
    assert second_committed.revision > first_committed.revision
    closed = presentation("closed")
    assert closed.revision > second_committed.revision
    await_idle(id)
    completed = await_event(id, accepted.id, "completed")
    assert completed.id == accepted.id
    snapshot = Worker.snapshot(id)
    assert snapshot.in_flight_text == ""
    assert snapshot.reply_presentation.phase == "closed"
    assert snapshot.reply_presentation.revision == closed.revision

    assert Enum.map(snapshot.reply_presentation.committed_messages, & &1.message_id) ==
             [first_committed.message_id, second_committed.message_id]

    raw_messages = Sessions.get_messages(id)
    event_messages = Enum.filter(raw_messages, &is_map(Map.get(&1, :reply_presentation)))

    assert Enum.map(event_messages, & &1.id) == [
             first_committed.message_id,
             second_committed.message_id
           ]

    assert Enum.map(event_messages, &raw_text/1) == [@event_text, "HEARTBEAT_OK"]

    for message <- event_messages do
      assert message.role == "assistant"
      assert message.reply_presentation == stamp(accepted.id)
    end

    caller_message = Enum.find(raw_messages, &(raw_text(&1) == "Caller HEARTBEAT_OK"))
    assert Map.get(caller_message, :reply_presentation) == nil

    effect =
      Enum.find(
        for(m <- raw_messages, %ToolResult{} = p <- m.parts, do: p),
        &(&1.tool_use_id == @effect_id)
      )

    assert not effect.is_error
    assert effect.content =~ "HEARTBEAT_OK"
    assert {:ok, before_replay} = Store.list_turns(id)

    assert Enum.filter(before_replay, &(Map.get(&1, :reply_presentation) != nil))
           |> Enum.map(& &1.parts) ==
             Enum.map(event_messages, &Synapsis.Message.encode(&1).parts)

    assert {:ok, aggregate} =
             Synapsis.Runtime.Store.load(native_event.store.namespace, native_event.run_id)

    native_history = aggregate.run.context.conversation.messages
    assert Enum.any?(native_history, &(&1.role == :assistant and text(&1.content) == @event_text))

    assert Enum.any?(
             native_history,
             &(&1.role == :assistant and text(&1.content) == "HEARTBEAT_OK")
           )

    {old_worker, _state} = worker_state(id)
    monitor = Process.monitor(old_worker)
    assert :ok = DynamicSupervisor.stop_session(id)
    assert_receive {:DOWN, ^monitor, :process, ^old_worker, :shutdown}, 10_000
    assert :ok = Sessions.ensure_running(id)
    await_idle(id)
    {new_worker, _state} = worker_state(id)
    assert new_worker != old_worker
    assert Worker.snapshot(id).reply_presentation == nil

    assert Enum.map(
             Enum.filter(Sessions.get_messages(id), &(Map.get(&1, :reply_presentation) != nil)),
             &{&1.id, raw_text(&1), &1.reply_presentation}
           ) ==
             Enum.map(event_messages, &{&1.id, raw_text(&1), &1.reply_presentation})

    assert :ok = Worker.send_message(id, @replay)
    assert_receive {:replay_request, replay}, 10_000

    assert Enum.any?(
             replay["messages"],
             &(&1["role"] == "assistant" and content(&1["content"]) == @event_text)
           )

    assert Enum.any?(
             replay["messages"],
             &(&1["role"] == "assistant" and content(&1["content"]) == "HEARTBEAT_OK")
           )

    await_idle(id)
    assert File.read!(effect_path(h)) == "effect\n"
    assert {:ok, after_replay} = Store.list_turns(id)
    assert Enum.take(after_replay, length(before_replay)) == before_replay
    requests = Agent.get(h.log, &Enum.map(&1, fn {request, _handler} -> request end))
    assert Enum.count(requests, &(List.last(user_texts(&1)) == @notice)) == 2
  end

  test "an ordinary literal heartbeat reply retains raw immediate deltas and untagged history",
       ctx do
    h = fixture(ctx.tmp_dir, [])
    owner = self()

    Gaoxy.Test.stub(h.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      conn = start_stream(conn)
      conn = chunk(conn, DeterministicProvider.text_chunk("HEARTBEAT_"))
      hold(owner, {:ordinary_prefix_sent, self()})

      DeterministicProvider.send_sse(conn, [
        DeterministicProvider.text_chunk("OK ordinary"),
        DeterministicProvider.finish_chunk("stop")
      ])
    end)

    assert :ok = Worker.send_message(h.session.id, "Ordinary literal reply")
    assert_receive {:ordinary_prefix_sent, handler}, 10_000
    assert delta("HEARTBEAT_") == %{text: "HEARTBEAT_"}
    snapshot = Worker.snapshot(h.session.id)
    assert snapshot.in_flight_text == "HEARTBEAT_"
    assert Map.get(snapshot, :reply_presentation) == nil
    send(handler, :release_event_reply)
    assert delta("OK ordinary") == %{text: "OK ordinary"}
    await_idle(h.session.id)
    [_, reply] = Sessions.get_messages(h.session.id)
    assert raw_text(reply) == "HEARTBEAT_OK ordinary"
    assert Map.get(reply, :reply_presentation) == nil
    assert {:ok, turns} = Store.list_turns(h.session.id)
    assert Enum.at(turns, 1).parts == [%{type: "text", text: "HEARTBEAT_OK ordinary"}]
    assert not Map.has_key?(Enum.at(turns, 1), :reply_presentation)
  end

  defp fixture(root, tools) do
    tag = Ecto.UUID.generate()
    directory = Path.join(root, tag)
    File.mkdir_p!(directory)

    h =
      SessionHarness.setup_session!(
        tmp_dir: directory,
        agent_name: "event-reply-#{tag}",
        install_provider?: false,
        session_config: %{
          "workspace_path" => directory,
          "subagents" => false,
          "memory_context" => false
        }
      )

    assert {:ok, agent} = Synapsis.AgentConfigs.update(h.agent_config, %{tools: tools})
    await_idle(h.session.id)
    log = start_supervised!({Agent, fn -> [] end}, id: tag)
    h = %{h | agent_config: agent}
    SessionHarness.subscribe!(h.session.id)

    on_exit(fn ->
      if Process.alive?(log) do
        for {_request, handler} <- Agent.get(log, & &1), do: send(handler, :release_event_reply)
      end

      SessionHarness.cleanup!(h)
    end)

    Map.put(h, :log, log)
  end

  defp install_event_provider(h) do
    owner = self()

    Gaoxy.Test.stub(h.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      Agent.update(h.log, &(&1 ++ [{request, self()}]))

      case List.last(user_texts(request)) do
        @prompt ->
          if has_result?(request, "event-reply-wake") do
            hold(owner, {:caller_accepted, request, self()})
            respond(conn, "Caller HEARTBEAT_OK")
          else
            tool(conn, @wake, "event-reply-wake", %{"text" => @notice})
          end

        @notice ->
          if has_result?(request, @effect_id) do
            hold(owner, {:effect_following, request, self()})
            conn = start_stream(conn)
            conn = chunk(conn, DeterministicProvider.text_chunk("HEARTBEAT_OK"))
            hold(owner, {:event_terminal_sent, self()})
            DeterministicProvider.send_sse(conn, [DeterministicProvider.finish_chunk("stop")])
          else
            conn = start_stream(conn)
            conn = chunk(conn, DeterministicProvider.text_chunk("HEARTBEAT_"))
            hold(owner, {:event_prefix_sent, request, self()})
            conn = chunk(conn, DeterministicProvider.text_chunk("OK"))
            hold(owner, {:event_marker_sent, self()})
            conn = chunk(conn, DeterministicProvider.text_chunk(" Event ready🙂🙂"))
            hold(owner, {:event_text_sent, self()})

            DeterministicProvider.send_sse(conn, [
              DeterministicProvider.tool_call_chunk("exec_command", @effect_id, %{
                "cmd" => "printf 'effect\\n' >> event-reply-effect.txt; printf HEARTBEAT_OK",
                "login" => false,
                "yield_time_ms" => 1000
              }),
              DeterministicProvider.finish_chunk("tool_calls")
            ])
          end

        @replay ->
          send(owner, {:replay_request, request})
          respond(conn, "Raw history recalled")
      end
    end)
  end

  defp start_stream(conn),
    do:
      conn |> Plug.Conn.put_resp_content_type("text/event-stream") |> Plug.Conn.send_chunked(200)

  defp chunk(conn, value) do
    {:ok, conn} = Plug.Conn.chunk(conn, "data: " <> Jason.encode!(value) <> "\n\n")
    conn
  end

  defp hold(owner, message) do
    send(owner, message)

    receive do
      :release_event_reply -> :ok
    after
      20_000 -> raise "event reply positive release handshake timed out"
    end
  end

  defp respond(conn, value),
    do:
      DeterministicProvider.send_sse(conn, [
        DeterministicProvider.text_chunk(value),
        DeterministicProvider.finish_chunk("stop")
      ])

  defp tool(conn, name, id, arguments),
    do:
      DeterministicProvider.send_sse(conn, [
        DeterministicProvider.tool_call_chunk(name, id, arguments),
        DeterministicProvider.finish_chunk("tool_calls")
      ])

  defp delta(text) do
    assert_receive {"text_delta", %{text: ^text} = payload}, 10_000
    payload
  end

  defp presentation(phase) do
    assert_receive {"reply_presentation", %{phase: ^phase} = payload}, 10_000
    payload
  end

  defp await_idle(id) do
    assert {:ok, :idle} =
             wait_for(fn ->
               case Worker.public_status(id) do
                 {:ok, %{runtime: %{active: false, phase: "idle"}}} -> {:ok, :idle}
                 _ -> :retry
               end
             end)
  end

  defp await_event(id, event_id, phase) do
    assert {:ok, event} =
             wait_for(fn ->
               with {:ok, entries} <- PendingInputStore.list_result(id),
                    event when not is_nil(event) <- Enum.find(entries, &(&1.id == event_id)),
                    true <- event.event["phase"] == phase,
                    do: {:ok, event},
                    else: (_ -> :retry)
             end)

    event
  end

  defp worker_state(id) do
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    {_, state} = :sys.get_state(worker)
    {worker, state}
  end

  defp runtime(id) do
    {_, state} = worker_state(id)
    runtime = :sys.get_state(state.runtime_pid)
    %{root: runtime.root, store: runtime.store, run_id: runtime.run_id}
  end

  defp effect_path(h), do: Path.join(h.tmp_dir, "event-reply-effect.txt")
  defp stamp(id), do: %{"version" => 1, "policy" => "manual_event_message", "occurrence_id" => id}

  defp provenance(h),
    do: %{
      "kind" => "internal_system",
      "source_tool" => "cron",
      "source_session_id" => h.session.id,
      "source_agent_id" => h.agent_config.id
    }

  defp raw_text(message),
    do: Enum.map_join(for(%Text{content: text} <- message.parts, do: text), "\n\n", & &1)

  defp text(binary) when is_binary(binary), do: binary
  defp text(blocks), do: Enum.map_join(blocks, "", &Map.get(&1, :text, ""))

  defp names(request),
    do: Enum.sort(Enum.map(request["tools"], &ToolName.decode(&1["function"]["name"])))

  defp has_result?(request, call_id),
    do: Enum.any?(request["messages"], &(&1["role"] == "tool" and &1["tool_call_id"] == call_id))

  defp user_texts(request),
    do:
      for(
        message <- request["messages"],
        message["role"] == "user",
        do: content(message["content"])
      )

  defp content(binary) when is_binary(binary), do: binary

  defp content(blocks) when is_list(blocks),
    do: Enum.map_join(blocks, "", &Map.get(&1, "text", ""))

  defp content(_), do: ""
end
