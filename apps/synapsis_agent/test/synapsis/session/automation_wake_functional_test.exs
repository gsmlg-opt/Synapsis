defmodule Synapsis.Session.AutomationWakeFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  import Synapsis.Agent.DaemonCase, only: [wait_for: 1]

  alias Synapsis.Agent.Runtime.SessionAdapter
  alias Synapsis.Agent.TestSupport.DeterministicProvider
  alias Synapsis.Session.{DynamicSupervisor, PendingInputStore, Store, Worker}
  alias Synapsis.{Message, Sessions}

  @moduletag :tmp_dir

  test "default wake is acknowledged while the original turn stays intact and adopts on prompt consumption",
       ctx do
    fixture = fixture(ctx.tmp_dir, hold: [0, 1])
    id = fixture.session.id
    tag = fixture.tag
    assert :ok = Worker.send_message(id, "Original active turn")
    assert_receive {:wake_request, ^tag, 0, first, first_handler}, 5_000
    assert wire_messages(first) == [{"user", "Original active turn"}]
    {worker, active} = worker_state(id)
    assert %{root: root} = SessionAdapter.automation_snapshot(active.runtime_pid)
    before = Backplane.AgentRuntime.Conversation.status(root).messages
    assert :erlang.trace(worker, true, [:receive, {:tracer, self()}]) == 1

    assert {:ok, %{accepted: true, event_id: event_id, target_session_id: ^id}} =
             Sessions.wake(id, " \uFEFFcheck the queue\n ", wake_opts(fixture))

    assert {:ok, ^event_id} = Ecto.UUID.cast(event_id)
    assert {:ok, [staged]} = PendingInputStore.list_result(id)
    assert staged.id == event_id
    assert staged.kind == "system_event"
    assert staged.status == "queued"
    assert staged.content == "check the queue"
    assert staged.event["mode"] == "next-heartbeat"
    assert staged.event["phase"] == "staged"
    assert staged.event["target_agent_id"] == fixture.agent.id
    assert {:ok, _owner_id} = Ecto.UUID.cast(staged.event["owner_id"])
    assert staged.input_provenance == provenance(fixture)
    assert {^worker, still_active} = worker_state(id)
    assert still_active.runtime_pid == active.runtime_pid
    assert still_active.runtime_run_id == active.runtime_run_id
    assert Backplane.AgentRuntime.Conversation.status(root).messages == before
    assert {:ok, [ordinary_input]} = Store.list_turns(id)
    assert ordinary_input.role == "user"

    send(first_handler, :continue_wake)
    assert_receive {:wake_request, ^tag, 1, following, event_handler}, 10_000

    assert wire_messages(following) == [
             {"user", "Original active turn"},
             {"assistant", "wake fixture reply 0"},
             {"user", "check the queue"}
           ]

    assert_receive {:trace, ^worker, :receive, {:runtime_started, event_epoch, event_run}}, 5_000

    assert_receive {:trace, ^worker, :receive,
                    {:runtime_event, ^event_epoch, ^event_run,
                     %{type: :prompt_consumed, mode: :new, message: runtime_message}}},
                   5_000

    assert is_binary(runtime_message.id)
    assert runtime_message.id != event_id
    started = await_event(id, event_id, "started")
    assert started.status == "consumed"
    assert started.event["run_id"] == event_run
    assert {:ok, [_, _, event_turn]} = Store.list_turns(id)
    assert event_turn.id == event_id
    assert event_turn.role == "user"
    assert event_turn.parts == [%{type: "text", text: "check the queue"}]
    assert event_turn.input_provenance == provenance(fixture)
    assert event_turn.internal_turn_source == "event"

    send(event_handler, :continue_wake)
    completed = await_event(id, event_id, "completed")
    assert completed.event["run_id"] == event_run
    await_idle(id)
    assert :erlang.trace(worker, false, [:receive]) == 1
    assert length(request_bodies(fixture)) == 2
  end

  test "now wakes the exact existing target and retains its own Agent separately from origin",
       ctx do
    source = fixture(ctx.tmp_dir)
    target = fixture(ctx.tmp_dir, hold: [0])
    id = target.session.id
    tag = target.tag
    assert :ok = DynamicSupervisor.stop_session(id)

    assert {:ok, %{accepted: true, event_id: event_id, target_session_id: ^id}} =
             Sessions.wake(id, "Explicit target notice",
               target_agent_id: target.agent.id,
               source_session_id: source.session.id,
               source_agent_id: source.agent.id,
               mode: "now"
             )

    assert_receive {:wake_request, ^tag, 0, request, handler}, 10_000
    assert request["model"] == target.agent.model
    assert wire_messages(request) == [{"user", "Explicit target notice"}]
    started = await_event(id, event_id, "started")
    assert started.event["mode"] == "now"
    assert started.event["target_agent_id"] == target.agent.id
    assert started.input_provenance == provenance(source)
    assert {:ok, target_meta} = Store.get_meta(id)
    assert target_meta.agent == target.session.agent
    assert {:ok, []} = Store.list_turns(source.session.id)
    assert request_bodies(source) == []
    send(handler, :continue_wake)
    await_event(id, event_id, "completed")
    await_idle(id)
    assert length(request_bodies(target)) == 1
  end

  test "identical accepted wakes keep distinct occurrences and each receives its own turn", ctx do
    fixture = fixture(ctx.tmp_dir, hold: [0, 1, 2])
    id = fixture.session.id
    tag = fixture.tag
    assert :ok = Worker.send_message(id, "Hold duplicate admission")
    assert_receive {:wake_request, ^tag, 0, _, original_handler}, 5_000

    assert {:ok, %{event_id: first_id, accepted: true}} =
             Sessions.wake(id, "same notice", wake_opts(fixture))

    assert {:ok, %{event_id: second_id, accepted: true}} =
             Sessions.wake(id, "same notice", wake_opts(fixture))

    assert first_id != second_id
    assert {:ok, [first, second]} = PendingInputStore.list_result(id)
    assert [first.id, second.id] == [first_id, second_id]
    assert [first.status, second.status] == ["queued", "queued"]
    send(original_handler, :continue_wake)
    assert_receive {:wake_request, ^tag, 1, first_request, first_handler}, 10_000
    assert List.last(wire_messages(first_request)) == {"user", "same notice"}
    await_event(id, first_id, "started")
    assert {:ok, [_, untouched]} = PendingInputStore.list_result(id)
    assert untouched == second
    send(first_handler, :continue_wake)
    assert_receive {:wake_request, ^tag, 2, second_request, second_handler}, 10_000
    assert List.last(wire_messages(second_request)) == {"user", "same notice"}
    await_event(id, first_id, "completed")
    await_event(id, second_id, "started")
    send(second_handler, :continue_wake)
    await_event(id, second_id, "completed")
    await_idle(id)
    assert {:ok, turns} = Store.list_turns(id)
    events = Enum.filter(turns, &(&1[:internal_turn_source] == "event"))
    assert Enum.map(events, & &1.id) == [first_id, second_id]
    assert length(request_bodies(fixture)) == 3
  end

  test "accepted prompt event prompt ordering survives the active-turn boundary", ctx do
    fixture = fixture(ctx.tmp_dir, hold: [0])
    id = fixture.session.id
    tag = fixture.tag
    assert :ok = Worker.send_message(id, "Active turn")
    assert_receive {:wake_request, ^tag, 0, _, handler}, 5_000
    assert :ok = Worker.send_message(id, "Prompt before event")

    assert {:ok, %{accepted: true, event_id: event_id}} =
             Sessions.wake(id, "Event between prompts", wake_opts(fixture))

    assert :ok = Worker.send_message(id, "Prompt after event")
    assert {:ok, queued} = PendingInputStore.list_result(id)

    assert Enum.map(queued, &{&1.kind, &1.content}) == [
             {"prompt", "Prompt before event"},
             {"system_event", "Event between prompts"},
             {"prompt", "Prompt after event"}
           ]

    send(handler, :continue_wake)

    for {index, expected} <- [
          {1, "Prompt before event"},
          {2, "Event between prompts"},
          {3, "Prompt after event"}
        ] do
      assert_receive {:wake_request, ^tag, ^index, request, _handler}, 10_000
      assert List.last(wire_messages(request)) == {"user", expected}
    end

    await_event(id, event_id, "completed")
    await_idle(id)
    assert {:ok, turns} = Store.list_turns(id)

    assert turns |> Enum.filter(&(&1.role == "user")) |> Enum.map(&hd(&1.parts).text) == [
             "Active turn",
             "Prompt before event",
             "Event between prompts",
             "Prompt after event"
           ]

    assert {:ok, consumed} = PendingInputStore.list_result(id)
    assert Enum.map(consumed, & &1.status) == ["consumed", "consumed", "consumed"]
    assert length(request_bodies(fixture)) == 4
  end

  test "completed automation append is committed before queued event preparation", ctx do
    fixture = fixture(ctx.tmp_dir, hold: [0, 1])
    id = fixture.session.id
    tag = fixture.tag
    assert :ok = Worker.send_message(id, "Original prompt")
    assert_receive {:wake_request, ^tag, 0, _, original_handler}, 5_000

    assert {:ok, %{accepted: true, event_id: event_id}} =
             Sessions.wake(id, "Observe delivered completion", wake_opts(fixture))

    assert {:ok, %{status: :deferred, message_id: completion_id}} =
             Sessions.append_automation_result(id, "Completion committed first")

    send(original_handler, :continue_wake)
    assert_receive {:wake_request, ^tag, 1, following, event_handler}, 10_000

    assert wire_messages(following) == [
             {"user", "Original prompt"},
             {"assistant", "wake fixture reply 0"},
             {"assistant", "Completion committed first"},
             {"user", "Observe delivered completion"}
           ]

    assert {:ok, [_, _, completion, event_turn]} = Store.list_turns(id)
    assert completion.id == completion_id
    assert event_turn.id == event_id
    send(event_handler, :continue_wake)
    await_event(id, event_id, "completed")
    await_idle(id)
    assert length(request_bodies(fixture)) == 2
  end

  test "completed event history survives Worker replacement and replays without another event turn",
       ctx do
    fixture = fixture(ctx.tmp_dir, hold: [0, 1])
    id = fixture.session.id
    tag = fixture.tag

    assert {:ok, %{accepted: true, event_id: event_id}} =
             Sessions.wake(id, "Completed event effect", wake_opts(fixture))

    assert_receive {:wake_request, ^tag, 0, _, event_handler}, 10_000
    send(event_handler, :continue_wake)
    completed = await_event(id, event_id, "completed")
    await_idle(id)
    assert {:ok, original_turns} = Store.list_turns(id)
    assert [event_message, _] = Message.list_by_session(id)
    assert event_message.id == event_id
    assert event_message.input_provenance == provenance(fixture)
    assert event_message.internal_turn_source == "event"
    {old_worker, _} = worker_state(id)
    old_ref = Process.monitor(old_worker)
    assert :ok = DynamicSupervisor.stop_session(id)
    assert_receive {:DOWN, ^old_ref, :process, ^old_worker, _}, 5_000
    assert :ok = Sessions.ensure_running(id)
    {new_worker, _} = worker_state(id)
    assert new_worker != old_worker
    assert :ok = Worker.send_message(id, "Recall the completed event")
    assert_receive {:wake_request, ^tag, 1, replay, replay_handler}, 10_000

    assert wire_messages(replay) == [
             {"user", "Completed event effect"},
             {"assistant", "wake fixture reply 0"},
             {"user", "Recall the completed event"}
           ]

    assert {:ok, [^completed]} = PendingInputStore.list_result(id)
    assert {:ok, turns_with_recall} = Store.list_turns(id)
    assert Enum.take(turns_with_recall, length(original_turns)) == original_turns
    send(replay_handler, :continue_wake)
    await_idle(id)
    assert length(request_bodies(fixture)) == 2
    assert {:ok, final_turns} = Store.list_turns(id)
    assert Enum.count(final_turns, &(&1.id == event_id)) == 1
  end

  test "ordinary boot recovery resumes the human prompt and retains staged prior-owner evidence",
       ctx do
    fixture = fixture(ctx.tmp_dir, hold: [0])
    id = fixture.session.id
    tag = fixture.tag
    await_idle(id)
    assert :ok = DynamicSupervisor.stop_session(id)

    assert {:ok, event} =
             PendingInputStore.append_event(id, %{
               content: "Prior owner staged event",
               owner_id: Ecto.UUID.generate(),
               target_agent_id: fixture.agent.id,
               mode: "next-heartbeat",
               input_provenance: provenance(fixture)
             })

    assert {:ok, prompt} = PendingInputStore.append_prompt(id, "Recovered human prompt", [])
    assert {:ok, ^prompt} = PendingInputStore.take_next_prompt(id)
    assert :ok = Sessions.ensure_running(id)
    assert_receive {:wake_request, ^tag, 0, request, handler}, 10_000
    assert wire_messages(request) == [{"user", "Recovered human prompt"}]
    retained = await_event(id, event.id, "owner_lost")
    assert retained.status == "owner_lost"
    assert retained.content == event.content
    assert retained.input_provenance == event.input_provenance
    send(handler, :continue_wake)
    await_idle(id)
    assert {:ok, [^retained, consumed_prompt]} = PendingInputStore.list_result(id)
    assert consumed_prompt.id == prompt.id
    assert consumed_prompt.status == "consumed"
    assert length(request_bodies(fixture)) == 1
  end

  test "ECMAScript nonblank NEL body survives event preparation and provider replay", ctx do
    fixture = fixture(ctx.tmp_dir, hold: [0, 1])
    id = fixture.session.id
    tag = fixture.tag
    body = "\u0085"

    assert {:ok, %{accepted: true, event_id: event_id}} =
             Sessions.wake(id, " \uFEFF" <> body <> "\n ", wake_opts(fixture))

    assert_receive {:wake_request, ^tag, 0, request, handler}, 10_000
    assert wire_messages(request) == [{"user", body}]
    await_event(id, event_id, "started")
    assert {:ok, [event_turn]} = Store.list_turns(id)
    assert event_turn.id == event_id
    assert event_turn.parts == [%{type: "text", text: body}]
    assert event_turn.input_provenance == provenance(fixture)
    assert event_turn.internal_turn_source == "event"
    send(handler, :continue_wake)
    completed = await_event(id, event_id, "completed")
    await_idle(id)

    assert :ok = DynamicSupervisor.stop_session(id)
    assert :ok = Sessions.ensure_running(id)
    assert :ok = Worker.send_message(id, "Recall NEL event")
    assert_receive {:wake_request, ^tag, 1, replay, replay_handler}, 10_000

    assert wire_messages(replay) == [
             {"user", body},
             {"assistant", "wake fixture reply 0"},
             {"user", "Recall NEL event"}
           ]

    assert {:ok, [^completed]} = PendingInputStore.list_result(id)
    send(replay_handler, :continue_wake)
    await_idle(id)
    assert length(request_bodies(fixture)) == 2
  end

  defp fixture(root, opts \\ []) do
    owner = self()
    http = Gaoxy.Test.open()
    tag = Ecto.UUID.generate()
    name = "automation-wake-#{tag}"
    requests = start_supervised!({Agent, fn -> [] end}, id: tag)

    assert :ok =
             Synapsis.Provider.Registry.register(name, %{
               type: "openai",
               api_key: "test-key",
               base_url: String.trim_trailing(Gaoxy.Test.url(http), "/")
             })

    assert {:ok, agent} =
             Synapsis.AgentConfigs.create(%{
               name: name,
               provider: name,
               model: "wake-model-#{tag}",
               tools: [],
               tool_contract_version: 1,
               config: %{"workspace_path" => root}
             })

    Gaoxy.Test.stub(http, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      handler = self()

      index =
        Agent.get_and_update(requests, fn entries ->
          {length(entries), entries ++ [%{request: request, handler: handler}]}
        end)

      send(owner, {:wake_request, tag, index, request, handler})

      if index in Keyword.get(opts, :hold, []) do
        receive do
          :continue_wake -> :ok
        after
          20_000 -> raise "wake fixture handshake timed out"
        end
      end

      DeterministicProvider.send_sse(conn, [
        DeterministicProvider.text_chunk("wake fixture reply #{index}"),
        DeterministicProvider.finish_chunk("stop")
      ])
    end)

    assert {:ok, session} =
             Sessions.create(name, %{
               agent: name,
               config: %{
                 "workspace_path" => root,
                 "subagents" => false,
                 "memory_context" => false
               }
             })

    assert :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session.id}")

    on_exit(fn ->
      if Process.alive?(requests) do
        for entry <- Agent.get(requests, & &1), do: send(entry.handler, :continue_wake)
      end

      Sessions.delete(session.id)
      Synapsis.AgentConfigs.delete(agent)
      Synapsis.Provider.Registry.unregister(name)
    end)

    %{session: session, agent: agent, requests: requests, tag: tag}
  end

  defp wake_opts(fixture) do
    [
      target_agent_id: fixture.agent.id,
      source_session_id: fixture.session.id,
      source_agent_id: fixture.agent.id
    ]
  end

  defp provenance(fixture) do
    %{
      "kind" => "internal_system",
      "source_tool" => "cron",
      "source_session_id" => fixture.session.id,
      "source_agent_id" => fixture.agent.id
    }
  end

  defp worker_state(id) do
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    {_state, data} = :sys.get_state(worker)
    {worker, data}
  end

  defp await_event(id, event_id, phase) do
    assert {:ok, event} =
             wait_for(fn ->
               with {:ok, inputs} <- PendingInputStore.list_result(id),
                    event when not is_nil(event) <- Enum.find(inputs, &(&1.id == event_id)),
                    true <- event.event["phase"] == phase do
                 {:ok, event}
               else
                 _ -> :retry
               end
             end)

    event
  end

  defp await_idle(id) do
    assert {:ok, :idle} =
             wait_for(fn ->
               case Worker.public_status(id) do
                 {:ok, %{runtime: %{active: false}}} -> {:ok, :idle}
                 _ -> :retry
               end
             end)
  end

  defp request_bodies(fixture),
    do: Agent.get(fixture.requests, &Enum.map(&1, fn e -> e.request end))

  defp wire_messages(request) do
    request["messages"]
    |> Enum.reject(&(&1["role"] == "system"))
    |> Enum.map(fn message ->
      content =
        case message["content"] do
          text when is_binary(text) ->
            text

          blocks when is_list(blocks) ->
            Enum.map_join(blocks, "", fn
              %{"type" => "text", "text" => text} -> text
              _ -> ""
            end)
        end

      {message["role"], content}
    end)
  end
end
