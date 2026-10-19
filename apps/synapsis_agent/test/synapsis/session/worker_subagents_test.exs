defmodule Synapsis.Session.WorkerSubagentsTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.{
    AbortableHTTP,
    DeterministicProvider,
    DeterministicTool,
    SessionHarness
  }

  alias Synapsis.Session.Worker

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} = ctx do
    opts = [tmp_dir: tmp_dir, text: "runtime answer", session_config: %{}]

    opts =
      if ctx[:approval_tool],
        do:
          opts ++
            [
              permission_mode: "ask",
              tool_behavior: :read_success,
              tool_opts: [permission_level: :write]
            ],
        else: opts

    harness = SessionHarness.setup_session!(opts)

    if ctx[:omitted_session_config] do
      :ok = Synapsis.Session.DynamicSupervisor.stop_session(harness.session.id)
      {:ok, meta} = Synapsis.Session.Store.get_meta(harness.session.id)
      :ok = Synapsis.Session.Store.put_meta(harness.session.id, Map.delete(meta, :config))
    end

    Bypass.stub(harness.provider.bypass, "POST", "/v1/chat/completions", fn conn ->
      DeterministicProvider.send_sse(conn, [
        DeterministicProvider.text_chunk("runtime answer"),
        DeterministicProvider.finish_chunk("stop")
      ])
    end)

    on_exit(fn -> SessionHarness.cleanup!(harness) end)
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    %{harness: harness, id: harness.session.id}
  end

  test "subagent setting persists and is restored by the Worker", %{id: id} do
    assert {:ok, %{config: %{"subagents" => true}}} = Worker.set_subagents(id, true)

    assert %{session: %{config: %{"subagents" => true}}, subagents: %{agents: []}} =
             Worker.snapshot(id)

    assert {:ok, %{config: %{"subagents" => false}}} = Worker.set_subagents(id, false)
    assert {:error, :invalid_setting} = Worker.set_subagents(id, "true")
  end

  test "default session runs one real Conversation and persists each message once", %{id: id} do
    assert %{session: %{config: config}} = Worker.snapshot(id)
    refute Map.has_key?(config, "subagents")
    assert :ok = Synapsis.Sessions.send_message(id, "hello runtime")
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert :waiting = Worker.get_status(id)

    assert [
             %{role: "user", parts: [%Synapsis.Part.Text{content: "hello runtime"}]},
             %{role: "assistant", parts: [%Synapsis.Part.Text{content: "runtime answer"}]}
           ] = Synapsis.Sessions.get_messages(id)

    assert :ok = Synapsis.Sessions.send_message(id, "again")
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert [_, _, %{role: "user"}, %{role: "assistant"}] = Synapsis.Sessions.get_messages(id)
    assert {:error, :not_found} = Worker.resolve_runtime(id, "stale-interaction", true)
    assert {:error, :retry_unavailable_with_subagents} = Worker.retry(id)
    assert {:error, :regenerate_unavailable_with_subagents} = Worker.regenerate(id, "any-message")
    assert {:error, :checkpoint_unavailable_with_subagents} = Worker.push_checkpoint(id)
    assert {:error, :checkpoint_unavailable_with_subagents} = Worker.rollback_checkpoint(id)
  end

  @tag omitted_session_config: true
  test "omitted session config drives real HTTP root, child and canonical tool history", %{
    id: id,
    harness: harness
  } do
    owner = self()

    install_provider(harness, fn conn, request ->
      send(owner, {:http_request, request})
      messages = request["messages"]

      cond do
        Enum.any?(messages, &(user_text(&1) == "child marker")) ->
          answer(conn, "child evidence")

        not tool_result?(messages, "spawn-child") ->
          call(conn, "spawn_agent", "spawn-child", %{
            "task_name" => "researcher",
            "message" => "child marker",
            "fork_turns" => "none"
          })

        not tool_result?(messages, "wait-child") ->
          call(conn, "wait_agent", "wait-child", %{"timeout_ms" => 10_000})

        true ->
          answer(conn, "parent combined evidence")
      end
    end)

    assert %{session: %{config: nil}} = Worker.snapshot(id)
    assert {:error, :retry_unavailable_with_subagents} = Worker.retry(id)
    assert {:error, :regenerate_unavailable_with_subagents} = Worker.regenerate(id, "any-message")
    assert {:error, :checkpoint_unavailable_with_subagents} = Worker.push_checkpoint(id)
    assert {:error, :checkpoint_unavailable_with_subagents} = Worker.rollback_checkpoint(id)
    assert :ok = Worker.send_message(id, "coordinate child")
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000

    assert %{subagents: %{agents: [%{name: "/root/researcher", status: :completed}]}} =
             Worker.snapshot(id)

    messages = Synapsis.Sessions.get_messages(id)
    parts = Enum.flat_map(messages, & &1.parts)
    assert Enum.count(parts, &match?(%Synapsis.Part.ToolUse{tool: "spawn_agent"}, &1)) == 1
    assert Enum.count(parts, &match?(%Synapsis.Part.ToolUse{tool: "wait_agent"}, &1)) == 1
    assert Enum.any?(parts, &match?(%Synapsis.Part.Text{content: "parent combined evidence"}, &1))

    assert Enum.any?(parts, fn
             %Synapsis.Part.Text{content: text} -> String.contains?(text, "child evidence")
             _ -> false
           end)

    assert_receive {:http_request, %{"tools" => tools}}, 1_000
    names = Enum.map(tools, &get_in(&1, ["function", "name"]))
    assert "spawn_agent" in names
    refute "task" in names
  end

  test "explicit opt-out uses the legacy turn and survives config refresh", %{id: id} do
    assert :ok = Worker.send_message(id, "default native turn")
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    {_state, native} = :sys.get_state(worker_pid(id))
    assert is_pid(native.runtime_pid)

    assert {:ok, _} = Worker.set_subagents(id, false)
    assert :ok = Worker.send_message(id, "legacy turn")
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert %{session: %{config: %{"subagents" => false}}} = Worker.snapshot(id)
    {_state, data} = :sys.get_state(worker_pid(id))
    assert data.runtime_pid == native.runtime_pid
    refute Synapsis.Session.Worker.Runtime.enabled?(data)
    assert {:error, :message_not_found} = Worker.regenerate(id, "missing-message")
    assert {:error, :no_checkpoint} = Worker.rollback_checkpoint(id)
    assert :ok = Worker.cancel(id)
    assert %{session: %{config: %{"subagents" => false}}} = Worker.snapshot(id)
    # A dormant native adapter must not intercept legacy cancellation.
    assert :sys.get_state(native.runtime_pid).error == nil
  end

  test "assistant-mode input queues behind one active runtime", %{id: id, harness: harness} do
    owner = self()

    install_provider(harness, fn conn, request ->
      if List.last(request["messages"]) |> user_text() == "first" do
        send(owner, {:provider_waiting, self()})

        receive do
          :release -> :ok
        after
          5_000 -> :ok
        end
      end

      answer(conn, "queued response")
    end)

    assert {:ok, _} = Worker.set_subagents(id, true)
    # Exercise the query-loop execution mode without replacing the fixture agent.
    pid = worker_pid(id)

    :sys.replace_state(pid, fn {state, data} -> {state, %{data | execution_mode: :query_loop}} end)

    assert :ok = Worker.send_message(id, "first")
    assert_receive {:provider_waiting, handler}, 5_000
    assert :ok = Worker.send_message(id, "second")
    assert_receive {"input_queued", %{content: "second"}}, 1_000
    assert {:error, :session_busy} = Worker.set_subagents(id, false)
    assert {:error, :session_busy} = Worker.switch_mode(id, "assistant_mode")
    send(handler, :release)
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000

    assert ["first", "second"] ==
             for(
               %{role: "user", parts: [%Synapsis.Part.Text{content: text}]} <-
                 Synapsis.Sessions.get_messages(id),
               do: text
             )
  end

  @tag approval_tool: true
  test "child approval remains actionable after its root completes", %{id: id, harness: harness} do
    install_provider(harness, fn conn, request ->
      messages = request["messages"]

      cond do
        Enum.any?(messages, &(user_text(&1) == "pending child")) ->
          if tool_result?(messages, "write-child"),
            do: answer(conn, "child denied"),
            else:
              call(conn, harness.tool_name, "write-child", %{
                "value" => "forbidden without approval"
              })

        not tool_result?(messages, "spawn-pending") ->
          call(conn, "spawn_agent", "spawn-pending", %{
            "task_name" => "writer",
            "message" => "pending child",
            "fork_turns" => "none"
          })

        true ->
          answer(conn, "root finished while child waits")
      end
    end)

    assert {:ok, _} = Worker.set_subagents(id, true)
    assert :ok = Worker.send_message(id, "delegate writing")
    assert_receive {"runtime_permissions", [%{interaction_id: interaction}]}, 10_000
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert %{runtime_permissions: [%{interaction_id: ^interaction}]} = Worker.snapshot(id)
    assert [] == DeterministicTool.executions(harness.tool_name)
    assert {:error, :subagents_active} = Worker.set_subagents(id, false)
    assert :ok = Worker.resolve_runtime(id, interaction, false)
    assert_receive {"subagents", %{agents: [%{name: "/root/writer", status: :completed}]}}, 10_000
    assert [] == DeterministicTool.executions(harness.tool_name)
    assert %{runtime_permissions: []} = Worker.snapshot(id)
  end

  test "confirmed cancellation retires a generation and the next prompt succeeds", %{
    id: id,
    harness: harness
  } do
    owner = self()

    install_provider(harness, fn conn, request ->
      if List.last(request["messages"]) |> user_text() == "cancel this" do
        conn = AbortableHTTP.arm(conn)
        send(owner, {:provider_waiting, self()})

        case AbortableHTTP.await(conn, :release, 5_000, owner) do
          :disconnected -> Plug.Conn.resp(conn, 204, "")
          _ -> answer(conn, "late answer")
        end
      else
        answer(conn, "after cancellation")
      end
    end)

    assert :ok = Worker.send_message(id, "cancel this")
    assert_receive {:provider_waiting, handler}, 5_000
    {_state, before} = :sys.get_state(worker_pid(id))
    assert :ok = Worker.cancel(id)
    assert_receive {"done", _}, 10_000
    assert :waiting = Worker.get_status(id)
    refute_receive {:run_event, %{type: "session.completed"}}, 50
    send(handler, :release)
    assert :ok = Worker.send_message(id, "continue")
    # A stale adapter cannot replace the current root identity or roster.
    send(worker_pid(id), {:runtime_started, before.runtime_epoch, "stale-root"})
    send(worker_pid(id), {:runtime_roster, before.runtime_epoch, %{agents: [%{name: "stale"}]}})
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert %{subagents: %{agents: []}} = Worker.snapshot(id)

    assert Enum.any?(Synapsis.Sessions.get_messages(id), fn message ->
             Enum.any?(
               message.parts,
               &match?(%Synapsis.Part.Text{content: "after cancellation"}, &1)
             )
           end)
  end

  defp install_provider(harness, fun) do
    Bypass.stub(harness.provider.bypass, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      fun.(conn, Jason.decode!(body))
    end)
  end

  defp call(conn, name, id, args),
    do:
      DeterministicProvider.send_sse(conn, [
        DeterministicProvider.tool_call_chunk(name, id, args),
        DeterministicProvider.finish_chunk("tool_calls")
      ])

  defp answer(conn, text),
    do:
      DeterministicProvider.send_sse(conn, [
        DeterministicProvider.text_chunk(text),
        DeterministicProvider.finish_chunk("stop")
      ])

  defp tool_result?(messages, id),
    do: Enum.any?(messages, &(&1["role"] == "tool" and &1["tool_call_id"] == id))

  defp user_text(%{"role" => "user", "content" => text}) when is_binary(text), do: text

  defp user_text(%{"role" => "user", "content" => parts}) when is_list(parts),
    do: Enum.map_join(parts, &(&1["text"] || ""))

  defp user_text(_), do: nil
  defp worker_pid(id), do: GenServer.whereis({:via, Registry, {Synapsis.Session.Registry, id}})
end
