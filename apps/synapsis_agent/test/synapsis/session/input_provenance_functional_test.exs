defmodule Synapsis.Session.InputProvenanceFunctionalTest do
  use ExUnit.Case, async: false

  import Synapsis.Agent.DaemonCase, only: [wait_for: 1]

  alias Synapsis.Agent.TestSupport.DeterministicProvider
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, InputContext, PendingInputStore, Store, Worker}
  alias Synapsis.{Message, Sessions}

  @moduletag :tmp_dir
  @child_prompt "ordinary delegated provenance fixture"

  test "explicit direct input reaches the root and retains its full message after normal restart",
       ctx do
    fixture = fixture(ctx.tmp_dir, hold: [0])
    id = fixture.session.id
    tag = fixture.tag
    captured = capture(id, "直接/É")

    assert :ok = Sessions.send_message(id, "Explicit direct prompt", [], captured)
    assert_receive {:input_request, ^tag, 0, request, handler}, 5_000
    assert wire_messages(request) == [{"user", "Explicit direct prompt"}]
    assert_root_context(id, captured)
    assert_user_messages(id, [{captured, "Explicit direct prompt"}])

    send(handler, :continue_input)
    await_idle(id)
    assert_user_messages(id, [{captured, "Explicit direct prompt"}])

    assert :ok = DynamicSupervisor.stop_session(id)
    assert :ok = Sessions.ensure_running(id)
    assert_user_messages(id, [{captured, "Explicit direct prompt"}])
    assert length(request_bodies(fixture)) == 1
  end

  test "explicit queued inputs retain their own IDs and contexts in normal FIFO turns", ctx do
    fixture = fixture(ctx.tmp_dir, hold: [0, 1, 2])
    id = fixture.session.id
    tag = fixture.tag
    first = capture(id, "first")
    second = capture(id, "second")
    third = capture(id, "third")

    assert :ok = Worker.send_message(id, "First prompt", [], first)
    assert_receive {:input_request, ^tag, 0, _, first_handler}, 5_000
    assert_root_context(id, first)
    assert :ok = Sessions.send_message(id, "Second prompt", [], second)
    assert :ok = Worker.send_message(id, "Third prompt", [], third)

    assert {:ok, queued} = PendingInputStore.list_result(id)

    assert Enum.map(queued, &{&1.id, &1.content, &1.status, &1.input_provenance}) == [
             {second["input_id"], "Second prompt", "queued", second},
             {third["input_id"], "Third prompt", "queued", third}
           ]

    send(first_handler, :continue_input)
    assert_receive {:input_request, ^tag, 1, second_request, second_handler}, 10_000

    assert wire_messages(second_request) == [
             {"user", "First prompt"},
             {"assistant", "input fixture reply 0"},
             {"user", "Second prompt"}
           ]

    assert_root_context(id, second)
    assert_user_messages(id, [{first, "First prompt"}, {second, "Second prompt"}])

    send(second_handler, :continue_input)
    assert_receive {:input_request, ^tag, 2, third_request, third_handler}, 10_000
    assert List.last(wire_messages(third_request)) == {"user", "Third prompt"}
    assert_root_context(id, third)
    send(third_handler, :continue_input)
    await_idle(id)

    assert_user_messages(id, [
      {first, "First prompt"},
      {second, "Second prompt"},
      {third, "Third prompt"}
    ])

    assert {:ok, consumed} = PendingInputStore.list_result(id)

    assert Enum.map(consumed, &{&1.id, &1.status, &1.input_provenance}) == [
             {second["input_id"], "consumed", second},
             {third["input_id"], "consumed", third}
           ]
  end

  test "a successful old arity prompt retains unavailable input provenance", ctx do
    fixture = fixture(ctx.tmp_dir, hold: [0])
    id = fixture.session.id
    tag = fixture.tag

    assert :ok = Sessions.send_message(id, "Ordinary legacy prompt")
    assert_receive {:input_request, ^tag, 0, request, handler}, 5_000
    assert wire_messages(request) == [{"user", "Ordinary legacy prompt"}]
    assert_root_context(id, nil)
    send(handler, :continue_input)
    await_idle(id)

    assert [%Message{input_provenance: nil}] =
             id |> Sessions.get_messages() |> Enum.filter(&(&1.role == "user"))

    assert {:ok, turns} = Store.list_turns(id)
    assert Enum.map(Enum.filter(turns, &(&1.role == "user")), & &1[:input_provenance]) == [nil]
  end

  test "an ordinary system event preserves its event origin and has no human input context",
       ctx do
    fixture = fixture(ctx.tmp_dir, hold: [0])
    id = fixture.session.id
    tag = fixture.tag

    expected = %{
      "kind" => "internal_system",
      "source_tool" => "cron",
      "source_session_id" => id,
      "source_agent_id" => fixture.agent.id
    }

    assert {:ok, %{accepted: true, event_id: event_id}} =
             Sessions.wake(id, "Ordinary event prompt",
               target_agent_id: fixture.agent.id,
               source_session_id: id,
               source_agent_id: fixture.agent.id,
               mode: "now"
             )

    assert_receive {:input_request, ^tag, 0, request, handler}, 10_000
    assert wire_messages(request) == [{"user", "Ordinary event prompt"}]
    assert_root_context(id, nil)
    send(handler, :continue_input)
    await_idle(id)

    assert [%Message{id: ^event_id, input_provenance: ^expected, internal_turn_source: "event"}] =
             id |> Sessions.get_messages() |> Enum.filter(&(&1.role == "user"))

    assert {:ok, turns} = Store.list_turns(id)

    assert [%{id: ^event_id, input_provenance: ^expected, internal_turn_source: "event"}] =
             Enum.filter(turns, &(&1.role == "user"))
  end

  test "ordinary native delegation retains root input custody and gives the child no human context",
       ctx do
    fixture = fixture(ctx.tmp_dir, hold: [0], native_child: true)
    id = fixture.session.id
    tag = fixture.tag
    captured = capture(id, "parent")

    assert :ok = Sessions.send_message(id, "Delegate one ordinary task", [], captured)
    assert_receive {:input_request, ^tag, 0, _, root_handler}, 5_000
    root = assert_root_context(id, captured)
    send(root_handler, :continue_input)
    assert_receive {:input_child, ^tag, child_handler}, 10_000

    child = :sys.get_state(root.manager).agents["/root/provenance_child"]
    assert is_pid(child.pid)
    adapter = assert_root_context(id, captured)
    child_state = :sys.get_state(child.pid)
    assert child_state.opts[:host_context][:input_context] == nil
    assert Map.get(adapter.runs[child_state.run.run_id].context, :input_context) == nil

    send(child_handler, :continue_child)
    await_idle(id)

    assert [%{name: "/root/provenance_child", status: :completed}] =
             Worker.snapshot(id).subagents.agents

    assert_user_messages(id, [{captured, "Delegate one ordinary task"}], native_rows: true)
  end

  defp fixture(root, opts) do
    owner = self()
    http = Gaoxy.Test.open()
    tag = Ecto.UUID.generate()
    name = "input-provenance-#{tag}"
    requests = start_supervised!({Agent, fn -> [] end}, id: tag)
    native_child? = Keyword.get(opts, :native_child, false)

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
               model: "input-model-#{tag}",
               tools: if(native_child?, do: ~w(spawn_agent wait_agent), else: []),
               tool_contract_version: 1,
               permission_mode: "yolo",
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

      send(owner, {:input_request, tag, index, request, handler})

      if index in Keyword.get(opts, :hold, []) do
        receive do
          :continue_input -> :ok
        after
          20_000 -> raise "input fixture handshake timed out"
        end
      end

      if native_child? do
        native_response(conn, request, owner, tag)
      else
        answer(conn, "input fixture reply #{index}")
      end
    end)

    assert {:ok, session} =
             Sessions.create(name, %{
               agent: name,
               config: %{
                 "workspace_path" => root,
                 "subagents" => native_child?,
                 "memory_context" => false
               }
             })

    on_exit(fn ->
      if Process.alive?(requests) do
        for entry <- Agent.get(requests, & &1) do
          send(entry.handler, :continue_input)
          send(entry.handler, :continue_child)
        end
      end

      Sessions.delete(session.id)
      Synapsis.AgentConfigs.delete(agent)
      Synapsis.Provider.Registry.unregister(name)
    end)

    %{session: session, agent: agent, tag: tag, requests: requests}
  end

  defp native_response(conn, request, owner, tag) do
    messages = request["messages"]

    cond do
      Enum.any?(wire_messages(request), &(&1 == {"user", @child_prompt})) ->
        send(owner, {:input_child, tag, self()})

        receive do
          :continue_child -> :ok
        after
          20_000 -> raise "child input fixture handshake timed out"
        end

        answer(conn, "ordinary child complete")

      Enum.any?(messages, &(&1["tool_call_id"] == "input-wait")) ->
        answer(conn, "ordinary delegation complete")

      Enum.any?(messages, &(&1["tool_call_id"] == "input-spawn")) ->
        tool_call(conn, "wait_agent", "input-wait", %{"timeout_ms" => 10_000})

      true ->
        tool_call(conn, "spawn_agent", "input-spawn", %{
          "task_name" => "provenance_child",
          "message" => @child_prompt,
          "fork_turns" => "none"
        })
    end
  end

  defp tool_call(conn, name, id, args) do
    DeterministicProvider.send_sse(conn, [
      DeterministicProvider.tool_call_chunk(ToolName.encode(name), id, args),
      DeterministicProvider.finish_chunk("tool_calls")
    ])
  end

  defp answer(conn, text) do
    DeterministicProvider.send_sse(conn, [
      DeterministicProvider.text_chunk(text),
      DeterministicProvider.finish_chunk("stop")
    ])
  end

  defp capture(id, label) do
    assert {:ok, context} =
             InputContext.capture(id, %{
               provider: "Explicit/聊天",
               account_id: "账户/Aa",
               conversation_id: "会话/#{label}",
               sender_id: " 发送者/#{label} "
             })

    context
  end

  defp assert_root_context(id, expected) do
    assert {:ok, adapter} =
             wait_for(fn ->
               [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
               {_phase, data} = :sys.get_state(worker)

               if is_pid(data.runtime_pid) do
                 state = :sys.get_state(data.runtime_pid)
                 if is_pid(state.root), do: {:ok, state}, else: :retry
               else
                 :retry
               end
             end)

    assert Map.get(adapter.context, :input_context) == expected
    assert :sys.get_state(adapter.root).opts[:host_context][:input_context] == expected
    adapter
  end

  defp assert_user_messages(id, expected, opts \\ []) do
    live = id |> Sessions.get_messages() |> user_messages(expected, opts)
    durable = id |> Message.list_by_session() |> user_messages(expected, opts)
    assert length(live) == length(expected)
    assert length(durable) == length(expected)
    assert {:ok, turns} = Store.list_turns(id)
    turns = user_messages(turns, expected, opts)
    assert length(turns) == length(expected)

    for {messages, {captured, text}} <- Enum.zip(Enum.zip(live, durable), expected) do
      {live_message, durable_message} = messages

      for message <- [live_message, durable_message] do
        assert message.id == captured["input_id"]
        assert message.input_provenance == captured
        encoded = message |> Message.encode() |> Jason.encode!() |> Jason.decode!()
        assert encoded["id"] == captured["input_id"]
        assert encoded["input_provenance"] == captured
        assert encoded["parts"] == [%{"type" => "text", "text" => text}]
      end
    end

    for {turn, {captured, text}} <- Enum.zip(turns, expected) do
      encoded = turn |> Jason.encode!() |> Jason.decode!()
      assert encoded["id"] == captured["input_id"]
      assert encoded["input_provenance"] == captured
      assert encoded["parts"] == [%{"type" => "text", "text" => text}]
    end
  end

  defp user_messages(messages, expected, opts) do
    users = Enum.filter(messages, &(&1.role == "user"))

    if Keyword.get(opts, :native_rows, false) do
      input_ids = Enum.map(expected, fn {captured, _text} -> captured["input_id"] end)
      {inputs, internal} = Enum.split_with(users, &(&1.id in input_ids))

      # Tool replies and child completion messages also use the host user role.
      # Verify them separately so every original input keeps the full assertions.
      markers =
        Enum.map(internal, fn message ->
          turn =
            case message do
              %Message{} -> Message.encode(message)
              turn -> turn
            end

          encoded = turn |> Jason.encode!() |> Jason.decode!()
          assert encoded["input_provenance"] == nil

          case encoded["parts"] do
            [%{"type" => "tool_result", "tool_use_id" => call_id, "is_error" => false}] ->
              assert call_id in ["input-spawn", "input-wait"]
              call_id

            [%{"type" => "text", "text" => text}] ->
              assert text ==
                       "Message Type: FINAL_ANSWER\nTask name: /root\n" <>
                         "Sender: /root/provenance_child\nPayload:\n" <>
                         "Agent /root/provenance_child completed: ordinary child complete"

              "child-completion"
          end
        end)

      assert Enum.sort(markers) == ["child-completion", "input-spawn", "input-wait"]
      inputs
    else
      users
    end
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
    do: Agent.get(fixture.requests, &Enum.map(&1, fn entry -> entry.request end))

  defp wire_messages(request) do
    request["messages"]
    |> Enum.reject(&(&1["role"] == "system"))
    |> Enum.map(fn message ->
      text =
        case message["content"] do
          text when is_binary(text) ->
            text

          blocks when is_list(blocks) ->
            Enum.map_join(blocks, "", fn
              %{"type" => "text", "text" => text} -> text
              _ -> ""
            end)

          nil ->
            ""
        end

      {message["role"], text}
    end)
  end
end
