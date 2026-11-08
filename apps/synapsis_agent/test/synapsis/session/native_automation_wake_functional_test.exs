defmodule Synapsis.Session.NativeAutomationWakeFunctionalTest do
  use ExUnit.Case, async: false

  import Synapsis.Agent.DaemonCase, only: [wait_for: 1]

  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Agent.Tools.AutomationWake
  alias Synapsis.Part.ToolResult
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, PendingInputStore, Store, Worker}
  alias Synapsis.Sessions

  @moduletag :tmp_dir
  @wake "synapsis::automations_wake"
  @notice "Run the accepted native wake effect"
  @prompt "Admit the native wakes"
  @replay "Recall the completed native wake"

  for occurrences <- [1, 2] do
    test "#{occurrences} identical caller-bound native wake occurrences accept before their exclusive effect turns",
         ctx do
      caller = fixture(ctx.tmp_dir, [@wake, "exec_command"])
      install_provider(caller, unquote(occurrences), %{"text" => " \uFEFF" <> @notice <> "\n "})
      id = caller.session.id
      assert :ok = Worker.send_message(id, @prompt)
      assert_receive {:caller_accepted, ^id, request, handler}, 10_000
      assert names(request) == Enum.sort([@wake, "exec_command"])
      caller_runtime = runtime(id)
      catalog = :sys.get_state(caller_runtime.root).catalog
      assert Enum.sort(Map.keys(catalog.registry.tools)) == Enum.sort([@wake, "exec_command"])
      assert catalog.registry.tools[@wake].backend == AutomationWake
      assert_native_receipts(caller_runtime, unquote(occurrences))

      assert {:ok, queued} = PendingInputStore.list_result(id)
      assert length(queued) == unquote(occurrences)
      assert length(Enum.uniq_by(queued, & &1.id)) == unquote(occurrences)
      {_worker, state} = worker_state(id)
      assert state.runtime_active
      assert MapSet.new(Enum.map(queued, & &1.id)) == state.pending_inputs.events

      for event <- queued do
        assert {:ok, event.id} == Ecto.UUID.cast(event.id)
        assert event.status == "queued"
        assert event.content == @notice
        assert event.event["phase"] == "staged"
        assert event.event["mode"] == "next-heartbeat"
        assert event.event["target_agent_id"] == caller.agent_config.id
        assert event.input_provenance == provenance(caller)
      end

      assert File.read(effect_path(caller)) == {:error, :enoent}
      assert {:ok, original_turns} = Store.list_turns(id)
      assert Enum.map(original_turns, & &1.role) == ["user"]
      assert List.last(user_texts(request)) == @prompt
      assert_tool_receipts_in_request(request, unquote(occurrences))
      send(handler, :release_native_wake)

      for {event, index} <- Enum.with_index(queued, 1) do
        assert_receive {:run_event, %{type: "session.completed"}}, 10_000
        assert_receive {:event_request, ^id, ^index, event_request, event_handler}, 10_000
        assert List.last(user_texts(event_request)) == @notice
        assert event_request["model"] == caller.agent_config.model
        started = await_event(id, event.id, "started")
        assert started.status == "consumed"
        assert_event_turn(caller, event.id, caller)

        assert File.read(effect_path(caller)) ==
                 if(index == 1,
                   do: {:error, :enoent},
                   else: {:ok, String.duplicate("effect\n", index - 1)}
                 )

        if index < length(queued) do
          assert {:ok, entries} = PendingInputStore.list_result(id)
          assert Enum.at(entries, index) == Enum.at(queued, index)
        end

        send(event_handler, :release_native_wake)
        assert_receive {:effect_following, ^id, ^index, following, effect_handler}, 10_000
        assert File.read!(effect_path(caller)) == String.duplicate("effect\n", index)
        effect_runtime = runtime(id)
        send(effect_handler, :release_native_wake)
        await_event(id, event.id, "completed")
        if index == length(queued), do: await_idle(id)
        assert_real_tool_result(caller, "event-effect-#{index}", following, effect_runtime)
      end

      assert_public_receipts(caller, unquote(occurrences))
      replay_completed(caller, queued, unquote(occurrences))
    end
  end

  test "explicit now uses the second existing Session's own Agent provider and model with caller provenance",
       ctx do
    caller = fixture(ctx.tmp_dir, [@wake])
    target = fixture(ctx.tmp_dir, ["exec_command"])
    assert caller.agent_config.id != target.agent_config.id
    assert caller.provider.name != target.provider.name
    assert caller.agent_config.model != target.agent_config.model

    install_provider(caller, 1, %{
      "text" => @notice,
      "mode" => "now",
      "session_id" => target.session.id,
      "agent_id" => target.agent_config.id
    })

    install_provider(target, 0, %{})
    assert :ok = DynamicSupervisor.stop_session(target.session.id)
    caller_id = caller.session.id
    target_id = target.session.id
    assert :ok = Worker.send_message(caller_id, @prompt)
    assert_receive {:caller_accepted, ^caller_id, accepted, caller_handler}, 10_000
    assert names(accepted) == [@wake]
    assert_tool_receipts_in_request(accepted, 1)
    assert_receive {:event_request, ^target_id, 1, request, event_handler}, 10_000
    assert names(request) == ["exec_command"]
    assert request["model"] == target.agent_config.model
    assert user_texts(request) == [@notice]
    assert {:ok, [accepted_event]} = PendingInputStore.list_result(target_id)
    event = await_event(target_id, accepted_event.id, "started")
    assert event.event["target_agent_id"] == target.agent_config.id
    assert event.event["mode"] == "now"
    assert event.input_provenance == provenance(caller)
    assert_event_turn(target, event.id, caller)
    {_worker, caller_state} = worker_state(caller_id)
    assert caller_state.runtime_active
    assert File.read(effect_path(target)) == {:error, :enoent}
    send(caller_handler, :release_native_wake)
    await_idle(caller_id)
    assert_public_receipts(caller, 1)
    assert {:ok, caller_turns} = Store.list_turns(caller_id)

    assert Enum.map(caller_turns, &{&1.role, Enum.map(&1.parts, fn part -> part.type end)}) == [
             {"user", ["text"]},
             {"assistant", ["tool_use"]},
             {"user", ["tool_result"]},
             {"assistant", ["text"]}
           ]

    assert for(
             turn <- caller_turns,
             turn.role == "user",
             %{type: "text", text: text} <- turn.parts,
             do: text
           ) == [@prompt]

    assert {:ok, target_meta} = Store.get_meta(target_id)
    assert target_meta.agent == target.agent_config.name
    assert target_meta.provider == target.provider.name
    assert target_meta.model == target.agent_config.model
    send(event_handler, :release_native_wake)
    assert_receive {:effect_following, ^target_id, 1, following, effect_handler}, 10_000
    assert File.read!(effect_path(target)) == "effect\n"
    effect_runtime = runtime(target_id)
    send(effect_handler, :release_native_wake)
    completed = await_event(target_id, event.id, "completed")
    await_idle(target_id)
    assert_real_tool_result(target, "event-effect-1", following, effect_runtime)
    replay_completed(target, [completed], 1)
  end

  defp fixture(root, tools) do
    tag = Ecto.UUID.generate()
    directory = Path.join(root, tag)
    File.mkdir_p!(directory)

    harness =
      SessionHarness.setup_session!(
        tmp_dir: directory,
        agent_name: "native-wake-#{tag}",
        install_provider?: false,
        session_config: %{
          "workspace_path" => directory,
          "subagents" => false,
          "memory_context" => false
        }
      )

    assert {:ok, configured} =
             Synapsis.AgentConfigs.update(harness.agent_config, %{
               tools: tools,
               model: "native-wake-model-#{tag}"
             })

    await_idle(harness.session.id)

    assert :ok =
             Sessions.switch_model(harness.session.id, harness.provider.name, configured.model)

    harness = %{harness | agent_config: configured}
    log = start_supervised!({Agent, fn -> [] end}, id: tag)
    SessionHarness.subscribe!(harness.session.id)

    on_exit(fn ->
      if Process.alive?(log) do
        for {_request, handler} <- Agent.get(log, & &1), do: send(handler, :release_native_wake)
      end

      SessionHarness.cleanup!(harness)
    end)

    Map.put(harness, :log, log)
  end

  defp install_provider(harness, count, arguments) do
    owner = self()
    id = harness.session.id

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      handler = self()
      Agent.update(harness.log, &(&1 ++ [{request, handler}]))
      prompt = List.last(user_texts(request))

      cond do
        prompt == @replay ->
          send(owner, {:replay_request, id, request})
          respond(conn, "Recalled completed wake")

        prompt == @notice ->
          index = Enum.count(user_texts(request), &(&1 == @notice))
          call_id = "event-effect-#{index}"

          if has_result?(request, call_id) do
            hold(owner, {:effect_following, id, index, request, self()})
            respond(conn, "Event effect completed #{index}")
          else
            hold(owner, {:event_request, id, index, request, self()})

            tool(conn, "exec_command", call_id, %{
              "cmd" => "printf 'effect\\n' >> native-wake-effect.txt",
              "login" => false,
              "yield_time_ms" => 1000
            })
          end

        prompt == @prompt ->
          admitted = Enum.count(1..count, &has_result?(request, "native-wake-#{&1}"))

          if admitted == count do
            hold(owner, {:caller_accepted, id, request, self()})
            respond(conn, "Wake accepted")
          else
            tool(conn, @wake, "native-wake-#{admitted + 1}", arguments)
          end
      end
    end)
  end

  defp hold(owner, message) do
    send(owner, message)

    receive do
      :release_native_wake -> :ok
    after
      20_000 -> raise "native wake positive release handshake timed out"
    end
  end

  defp tool(conn, name, call_id, arguments),
    do:
      DeterministicProvider.send_sse(conn, [
        DeterministicProvider.tool_call_chunk(name, call_id, arguments),
        DeterministicProvider.finish_chunk("tool_calls")
      ])

  defp respond(conn, text),
    do:
      DeterministicProvider.send_sse(conn, [
        DeterministicProvider.text_chunk(text),
        DeterministicProvider.finish_chunk("stop")
      ])

  defp assert_native_receipts(runtime, count) do
    messages = Backplane.AgentRuntime.Conversation.status(runtime.root).messages

    for index <- 1..count do
      result =
        Enum.find(messages, &(&1.role == :tool and &1[:tool_call_id] == "native-wake-#{index}"))

      assert result.result.structured == %{"ok" => true}
      assert Jason.decode!(result.result.content) == %{"ok" => true}
    end
  end

  defp assert_tool_receipts_in_request(request, count) do
    for index <- 1..count do
      result =
        Enum.find(
          request["messages"],
          &(&1["role"] == "tool" and &1["tool_call_id"] == "native-wake-#{index}")
        )

      assert Jason.decode!(content(result["content"])) == %{"ok" => true}
    end
  end

  defp assert_public_receipts(harness, count) do
    for index <- 1..count do
      result = tool_result(harness.session.id, "native-wake-#{index}")
      assert result.is_error == false
      assert Jason.decode!(result.content) == %{"ok" => true}
      assert result.projection["version"] == 1
      assert result.projection["result"]["structured"] == %{"ok" => true}
      assert_durable_result(harness.session.id, result)
    end
  end

  defp assert_real_tool_result(harness, call_id, following, runtime) do
    result = tool_result(harness.session.id, call_id)
    assert result.is_error == false

    assert Enum.any?(
             following["messages"],
             &(&1["role"] == "tool" and &1["tool_call_id"] == call_id and
                 content(&1["content"]) == result.content)
           )

    assert_durable_result(harness.session.id, result)
    assert {:ok, aggregate} = Synapsis.Runtime.Store.load(runtime.store.namespace, runtime.run_id)

    native =
      Enum.find(
        aggregate.run.context.conversation.messages,
        &(&1.role == :tool and &1[:tool_call_id] == call_id)
      )

    assert native.result[:is_error] != true
  end

  defp assert_durable_result(id, result) do
    assert {:ok, turns} = Store.list_turns(id)

    assert Enum.any?(
             for(turn <- turns, part <- turn.parts, do: part),
             &(&1[:type] == "tool_result" and &1[:tool_use_id] == result.tool_use_id and
                 &1[:content] == result.content and &1[:projection] == result.projection)
           )
  end

  defp assert_event_turn(target, event_id, source) do
    assert {:ok, turns} = Store.list_turns(target.session.id)
    event = Enum.find(turns, &(&1.id == event_id))
    assert event.role == "user"
    assert event.parts == [%{type: "text", text: @notice}]
    assert event.input_provenance == provenance(source)
    assert event.internal_turn_source == "event"
  end

  defp replay_completed(harness, events, count) do
    id = harness.session.id
    assert {:ok, before} = Store.list_turns(id)
    assert :ok = DynamicSupervisor.stop_session(id)
    assert :ok = Sessions.ensure_running(id)
    assert :ok = Worker.send_message(id, @replay)
    assert_receive {:replay_request, ^id, replay}, 10_000
    await_idle(id)
    assert Enum.count(user_texts(replay), &(&1 == @notice)) == count
    assert has_result?(replay, "event-effect-#{count}")
    assert File.read!(effect_path(harness)) == String.duplicate("effect\n", count)
    assert {:ok, after_replay} = Store.list_turns(id)
    assert Enum.take(after_replay, length(before)) == before
    assert {:ok, retained} = PendingInputStore.list_result(id)
    assert Enum.map(retained, & &1.id) == Enum.map(events, & &1.id)
    assert Enum.all?(retained, &(&1.event["phase"] == "completed"))
    requests = Agent.get(harness.log, &Enum.map(&1, fn {request, _} -> request end))
    assert Enum.count(requests, &(List.last(user_texts(&1)) == @notice)) == count * 2
  end

  defp await_event(id, event_id, phase) do
    assert {:ok, event} =
             wait_for(fn ->
               with {:ok, entries} <- PendingInputStore.list_result(id),
                    event when not is_nil(event) <- Enum.find(entries, &(&1.id == event_id)),
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
                 {:ok, %{runtime: %{active: false, phase: "idle"}}} -> {:ok, :idle}
                 _ -> :retry
               end
             end)
  end

  defp tool_result(id, call_id) do
    assert %ToolResult{} =
             result =
             Enum.find(
               for(
                 message <- Sessions.get_messages(id),
                 %ToolResult{} = part <- message.parts,
                 do: part
               ),
               &(&1.tool_use_id == call_id)
             )

    result
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

  defp provenance(harness),
    do: %{
      "kind" => "internal_system",
      "source_tool" => "cron",
      "source_session_id" => harness.session.id,
      "source_agent_id" => harness.agent_config.id
    }

  defp effect_path(harness), do: Path.join(harness.tmp_dir, "native-wake-effect.txt")

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

  defp content(text) when is_binary(text), do: text

  defp content(blocks) when is_list(blocks),
    do: Enum.map_join(blocks, "", &Map.get(&1, "text", ""))

  defp content(_), do: ""
end
