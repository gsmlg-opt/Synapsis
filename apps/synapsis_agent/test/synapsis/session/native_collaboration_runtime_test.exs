defmodule Synapsis.Session.NativeCollaborationRuntimeTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex.Backend
  alias Backplane.AgentRuntime.Error
  alias Synapsis.Agent.TestSupport.{AbortableHTTP, DeterministicProvider, SessionHarness}
  alias Synapsis.Part.ToolResult
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{Store, Worker}

  @moduletag :tmp_dir
  @collaboration ~w(spawn_agent send_message followup_task interrupt_agent list_agents wait_agent)
  @get "synapsis::workspace_memory_get"
  @child "native collaboration child marker"
  @memory "native-collaboration-memory-evidence"

  setup %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "MEMORY.md"), @memory <> "\n")

    harness =
      SessionHarness.setup_session!(
        tmp_dir: tmp_dir,
        install_provider?: false,
        session_config: %{"memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)
    assert {:ok, _} = Synapsis.AgentConfigs.update(harness.agent_config, %{tools: @collaboration})
    SessionHarness.subscribe!(harness.session.id)
    SessionHarness.ensure_running!(harness.session.id)
    %{harness: harness, id: harness.session.id}
  end

  test "explicit collaboration selection advertises unchanged descriptors and completes spawn and wait",
       ctx do
    install_provider(ctx.harness, :spawn)
    assert :ok = Worker.send_message(ctx.id, "Coordinate native collaboration")
    assert_receive {:collaboration_request, request, handler}, 5_000
    assert Enum.sort(wire_names(request)) == Enum.sort(@collaboration)
    runtime = runtime(ctx.id)
    catalog = :sys.get_state(runtime.root).catalog

    for name <- @collaboration do
      descriptor = catalog.registry.tools[name]
      assert descriptor.backend == Backend
      assert descriptor.tool_revision == 1

      assert %{family: :collaboration, profile: :v2, runtime: manager, session_binding: binding} =
               descriptor.backend_context

      assert manager == runtime.manager
      assert binding.run_id == runtime.run_id
    end

    send(handler, :release_collaboration_response)
    assert_completed()
    assert_received :native_collaboration_child_requested
    assert [%ToolResult{is_error: false}, %ToolResult{is_error: false}] = tool_results(ctx.id)
    assert length(tool_intents(runtime)) == 2

    assert [%{name: "/root/researcher", status: :completed}] =
             Worker.snapshot(ctx.id).subagents.agents

    assert {:ok, turns} = Store.list_turns(ctx.id)

    assert length(
             for turn <- turns,
                 part <- turn.parts,
                 part.type == "tool_result",
                 do: part.projection
           ) == 2
  end

  test "child admission retains selected host tools alongside native collaboration", ctx do
    assert {:ok, _} =
             Synapsis.AgentConfigs.update(ctx.harness.agent_config, %{
               tools: [@get | @collaboration]
             })

    install_provider(ctx.harness, :spawn_host)
    assert :ok = Worker.send_message(ctx.id, "Coordinate a child with workspace memory access")
    assert_receive {:collaboration_request, request, handler}, 5_000
    assert Enum.sort(wire_names(request)) == Enum.sort([@get | @collaboration])
    runtime = runtime(ctx.id)
    send(handler, :release_collaboration_response)
    assert_completed()
    assert_received :native_collaboration_child_requested
    assert_received {:native_child_memory_read, memory_content}
    assert memory_content =~ @memory

    child_request =
      Agent.get(ctx.harness.counter, fn state ->
        Enum.find(state.provider_requests, fn request ->
          Enum.any?(request["messages"], &(user_text(&1) == @child))
        end)
      end)

    assert Enum.sort(wire_names(child_request)) == Enum.sort([@get | @collaboration])
    assert [%ToolResult{is_error: false}, %ToolResult{is_error: false}] = tool_results(ctx.id)
    assert length(tool_intents(runtime)) == 2
  end

  for decision <- [true, false] do
    @decision decision
    test "trusted operator #{@decision} resolves the observed child approval", ctx do
      assert {:ok, _} =
               Synapsis.AgentConfigs.update(ctx.harness.agent_config, %{
                 tools: [@get | @collaboration]
               })

      update_permission(ctx.id, &%{&1 | mode: :interactive, allow_read: :ask})
      install_provider(ctx.harness, :spawn_host)
      assert :ok = Worker.send_message(ctx.id, "Ask before the child reads memory")
      assert_receive {:collaboration_request, _, handler}, 5_000
      runtime = runtime(ctx.id)
      send(handler, :release_collaboration_response)
      assert_receive {"runtime_permissions", [%{interaction_id: id} = pending]}, 5_000
      assert pending.request.tool_name == @get
      assert pending.request.arguments == %{"path" => "MEMORY.md"}
      assert pending.child.name == "/root/researcher"
      assert {:ok, child} = Synapsis.Runtime.Store.load(runtime.store.namespace, pending.run_id)
      refute Enum.any?(child.run.execution_intents, fn {_, intent} -> intent.type == :tool end)
      assert {:error, :not_found} = Worker.resolve_runtime(ctx.id, "unobserved-approval", true)

      if @decision do
        %{destination: {:managed, manager, correlation}, request: original} =
          :sys.get_state(runtime.adapter).pending[id]

        trusted = %{scope: original["scope"], operation: original["operation"]}

        for {field, value} <- [
              manager_id: "stale-manager",
              run_id: "stale-run",
              incarnation: correlation.incarnation + 1,
              interaction_id: "stale-interaction"
            ] do
          assert {:error, %Error{}} =
                   Synapsis.Agent.Tools.Approval.resolve_managed(
                     manager,
                     Map.put(correlation, field, value),
                     :approved,
                     trusted
                   )

          assert :sys.get_state(runtime.adapter).pending[id].request == original
        end

        assert {:ok, unchanged} =
                 Synapsis.Runtime.Store.load(runtime.store.namespace, pending.run_id)

        refute Enum.any?(unchanged.run.execution_intents, fn {_, intent} ->
                 intent.type == :tool
               end)
      end

      assert :ok = Worker.resolve_runtime(ctx.id, id, @decision)
      assert_receive {:native_child_memory_read, content}, 5_000
      assert String.contains?(inspect(content), @memory) == @decision
      assert_receive {"runtime_permissions", []}, 5_000
      assert_completed()
      assert {:error, :not_found} = Worker.resolve_runtime(ctx.id, id, true)
    end
  end

  test "child approval rechecks permission after the operator answers", ctx do
    assert {:ok, _} =
             Synapsis.AgentConfigs.update(ctx.harness.agent_config, %{
               tools: [@get | @collaboration]
             })

    update_permission(ctx.id, &%{&1 | mode: :interactive, allow_read: :ask})
    install_provider(ctx.harness, :spawn_host)
    assert :ok = Worker.send_message(ctx.id, "Recheck child access after approval")
    assert_receive {:collaboration_request, _, handler}, 5_000
    runtime = runtime(ctx.id)
    send(handler, :release_collaboration_response)
    assert_receive {"runtime_permissions", [%{interaction_id: id, run_id: child_run}]}, 5_000
    update_permission(ctx.id, &%{&1 | allow_read: :deny})
    assert :ok = Worker.resolve_runtime(ctx.id, id, true)
    assert_receive {:native_child_memory_read, content}, 5_000
    refute inspect(content) =~ @memory
    assert_completed()
    assert {:ok, child} = Synapsis.Runtime.Store.load(runtime.store.namespace, child_run)
    refute Enum.any?(child.run.execution_intents, fn {_, intent} -> intent.type == :tool end)
  end

  test "orchestration remains available when all four ordinary permission levels deny", ctx do
    update_permission(ctx.id, fn raw ->
      %{
        raw
        | allow_read: :deny,
          allow_write: :deny,
          allow_execute: :deny,
          allow_destructive: :deny
      }
    end)

    install_provider(ctx.harness, :list)
    assert :ok = Worker.send_message(ctx.id, "List the native agent tree")
    assert_receive {:collaboration_request, _request, handler}, 5_000
    runtime = runtime(ctx.id)
    send(handler, :release_collaboration_response)
    assert_completed()
    assert [%ToolResult{is_error: false}] = tool_results(ctx.id)
    assert [_] = tool_intents(runtime)
  end

  for decision <- [:deny, :ask] do
    @decision decision
    test "autonomous explicit spawn #{@decision} creates no child or execution intent", ctx do
      update_permission(
        ctx.id,
        &%{&1 | mode: :autonomous, tool_overrides: %{"spawn_agent" => @decision}}
      )

      install_provider(ctx.harness, :spawn)
      assert :ok = Worker.send_message(ctx.id, "Try native spawn")
      assert_receive {:collaboration_request, _request, handler}, 5_000
      runtime = runtime(ctx.id)
      send(handler, :release_collaboration_response)
      assert_completed()
      assert_no_spawn(ctx.id, runtime)
    end
  end

  test "spawn override revoked while the provider waits is checked before native intent", ctx do
    install_provider(ctx.harness, :spawn)
    assert :ok = Worker.send_message(ctx.id, "Try native spawn after permission refresh")
    assert_receive {:collaboration_request, _request, handler}, 5_000
    runtime = runtime(ctx.id)
    update_permission(ctx.id, &%{&1 | tool_overrides: %{"spawn_agent" => :deny}})
    send(handler, :release_collaboration_response)
    assert_completed()
    assert_no_spawn(ctx.id, runtime)
  end

  test "an unselected collaboration restriction does not block a selected workspace read", ctx do
    assert {:ok, _} = Worker.set_subagents(ctx.id, false)
    assert {:ok, _} = Synapsis.AgentConfigs.update(ctx.harness.agent_config, %{tools: [@get]})
    update_permission(ctx.id, &%{&1 | tool_overrides: %{"spawn_agent" => :deny}})
    install_provider(ctx.harness, :memory)
    assert :ok = Worker.send_message(ctx.id, "Read workspace memory with native tools")
    assert_receive {:collaboration_request, request, handler}, 5_000
    assert wire_names(request) == [@get]
    runtime = runtime(ctx.id)
    send(handler, :release_collaboration_response)
    assert_completed()
    assert [%ToolResult{is_error: false, content: content}] = tool_results(ctx.id)
    assert content =~ @memory
    assert [_] = tool_intents(runtime)
  end

  defp install_provider(harness, scenario) do
    owner = self()

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      Agent.update(harness.counter, &%{&1 | provider_requests: &1.provider_requests ++ [request]})
      messages = request["messages"]

      cond do
        Enum.any?(messages, &(user_text(&1) == @child)) ->
          send(owner, :native_collaboration_child_requested)

          case {scenario, Enum.find(messages, &(&1["tool_call_id"] == "child-memory"))} do
            {:spawn_host, nil} ->
              call(conn, @get, "child-memory", %{"path" => "MEMORY.md"})

            {:spawn_host, result} ->
              send(owner, {:native_child_memory_read, result["content"]})
              answer(conn, "native child complete")

            _ ->
              answer(conn, "native child complete")
          end

        result =
            Enum.find(messages, &(&1["role"] == "tool" and &1["tool_call_id"] == "native-spawn")) ->
          if Enum.any?(messages, &(&1["role"] == "tool" and &1["tool_call_id"] == "native-wait")) or
               denied?(result) do
            answer(conn, "native collaboration complete")
          else
            call(conn, "wait_agent", "native-wait", %{"timeout_ms" => 10_000})
          end

        Enum.any?(messages, &(&1["role"] == "tool")) ->
          answer(conn, "native collaboration complete")

        true ->
          send(owner, {:collaboration_request, request, self()})

          case AbortableHTTP.await(conn, :release_collaboration_response, 5_000, owner) do
            {:released, conn} -> initial_call(conn, scenario)
            {:disconnected, conn} -> conn
            {:timeout, conn} -> answer(conn, "provider gate timed out")
          end
      end
    end)
  end

  defp initial_call(conn, scenario) when scenario in [:spawn, :spawn_host],
    do:
      call(conn, "spawn_agent", "native-spawn", %{
        "task_name" => "researcher",
        "message" => @child,
        "fork_turns" => "none"
      })

  defp initial_call(conn, :list), do: call(conn, "list_agents", "native-list", %{})

  defp initial_call(conn, :memory),
    do: call(conn, @get, "native-memory", %{"path" => "MEMORY.md"})

  defp call(conn, name, id, args) do
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

  defp denied?(result),
    do:
      String.contains?(inspect(result["content"]), [
        "forbidden",
        "denied",
        "approval_required",
        "freshness_changed"
      ])

  defp user_text(%{"role" => "user", "content" => text}) when is_binary(text), do: text

  defp user_text(%{"role" => "user", "content" => parts}) when is_list(parts),
    do: Enum.map_join(parts, &(&1["text"] || ""))

  defp user_text(_), do: nil

  defp update_permission(id, update) do
    assert :ok = Store.put_value(id, "permission", update.(Store.get_value(id, "permission")))
  end

  defp runtime(id) do
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    {_phase, data} = :sys.get_state(worker)
    assert is_pid(data.runtime_pid)
    state = :sys.get_state(data.runtime_pid)
    assert is_pid(state.root)

    %{
      adapter: data.runtime_pid,
      root: state.root,
      manager: state.manager,
      store: state.store,
      run_id: state.run_id
    }
  end

  defp tool_results(id),
    do:
      for(
        message <- Synapsis.Sessions.get_messages(id),
        %ToolResult{} = result <- message.parts,
        do: result
      )

  defp tool_intents(runtime) do
    assert {:ok, aggregate} = Synapsis.Runtime.Store.load(runtime.store.namespace, runtime.run_id)
    aggregate.run.execution_intents |> Map.values() |> Enum.filter(&(&1.type == :tool))
  end

  defp wire_names(request),
    do: Enum.map(request["tools"] || [], &ToolName.decode(&1["function"]["name"]))

  defp assert_completed, do: assert_receive({:run_event, %{type: "session.completed"}}, 15_000)

  defp assert_no_spawn(id, runtime) do
    assert tool_intents(runtime) == []
    assert [%ToolResult{is_error: true}] = tool_results(id)
    assert Worker.snapshot(id).subagents.agents == []
    assert Worker.snapshot(id).runtime_permissions == []
    refute_received :native_collaboration_child_requested
  end
end
