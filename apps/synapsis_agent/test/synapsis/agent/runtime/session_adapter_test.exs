defmodule Synapsis.Agent.Runtime.SessionAdapterTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.Runtime.SessionAdapter
  alias Synapsis.Tool.Capability.PolicySnapshot
  alias Synapsis.Tool.Registry

  defmodule Provider do
    @behaviour Backplane.AgentRuntime.ConversationAdapter
    def stream(request, context) do
      send(context.test_pid, {:runtime_request, request})
      context.script.(request)
    end
  end

  defmodule Write do
    use Synapsis.Tool
    def name, do: "runtime_subagent_write"
    def description, do: "Inert write permission fixture"
    def permission_level, do: :write

    def parameters,
      do: %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

    def execute(_, _), do: {:ok, "written"}
  end

  defmodule FailProjection do
    defdelegate get(key, opts), to: Concord.Turso
    defdelegate prefix_scan(key, opts), to: Concord.Turso

    def txn(spec, opts) do
      if Enum.any?(spec.success, fn {:put, key, _, _} -> String.contains?(key, "projections/") end),
         do: {:error, :projection_write_failed},
         else: Concord.Turso.txn(spec, opts)
    end
  end

  defmodule FailRuntimeRead do
    defdelegate prefix_scan(key, opts), to: Concord.Turso
    defdelegate txn(spec, opts), to: Concord.Turso

    def get("coord/runtime/runs/" <> _, _opts), do: {:error, :runtime_read_failed}
    def get(key, opts), do: Concord.Turso.get(key, opts)
  end

  setup do
    :ok = Registry.register_module(Write.name(), Write)
    on_exit(fn -> Registry.unregister(Write.name()) end)
    id = Ecto.UUID.generate()

    context = %{
      session: %Synapsis.Session{id: id, model: "fixture-model"},
      agent: %{tools: [], model: "fixture-model", reasoning_effort: "medium"},
      provider_config: %{type: "openai"},
      project_path: File.cwd!(),
      messages: [],
      system_prompt: "Fixture system",
      policy_snapshot: PolicySnapshot.from_permission_mode("ask", session_id: id)
    }

    %{id: id, context: context}
  end

  test "real root spawns, receives completion, follows up with preserved history, and starts a fresh turn",
       ctx do
    script = fn request ->
      if String.starts_with?(request.run_id, "/root/") do
        [completed("child finished")]
      else
        calls = calls(request.messages)
        next_turn? = Enum.any?(request.messages, &(text(&1) == "next turn"))

        case {next_turn?, length(calls)} do
          {true, 0} ->
            tool("list_agents", %{}, 0)

          {true, _} ->
            [completed("next root finished")]

          {false, 0} ->
            tool(
              "spawn_agent",
              %{"task_name" => "child", "message" => "first task", "fork_turns" => "all"},
              0
            )

          {false, 1} ->
            tool("wait_agent", %{"timeout_ms" => 10_000}, 1)

          {false, 2} ->
            tool("followup_task", %{"target" => "child", "message" => "second task"}, 2)

          {false, 3} ->
            tool("wait_agent", %{"timeout_ms" => 10_000}, 3)

          {false, 4} ->
            tool("list_agents", %{}, 4)

          _ ->
            [completed("root finished")]
        end
      end
    end

    adapter = start_adapter(ctx, script)
    :ok = SessionAdapter.prompt(adapter, ctx.context, "run chain")
    assert_receive {:runtime_started, 1, run_id}, 2_000
    assert_receive {:runtime_history, 1, ^run_id, history}, 10_000
    assert_receive {:runtime_event, 1, ^run_id, %{type: :run_completed}}, 2_000

    assert Enum.any?(
             history,
             &(Map.has_key?(&1, :collaboration) or
                 not is_nil(get_in(&1, [Access.key(:metadata, %{}), :collaboration])))
           )

    assert Enum.any?(history, &(text(&1) =~ "child finished"))
    roster = SessionAdapter.snapshot(adapter)
    assert [%{name: "/root/child", incarnation: 2, status: :completed}] = roster.agents
    {:ok, intents} = Synapsis.Runtime.Store.list_facts(ctx.id, :admission_intent)
    {:ok, receipts} = Synapsis.Runtime.Store.list_facts(ctx.id, :admission_receipt)
    assert length(intents) == 2
    assert Enum.count(receipts, &(&1.status == :created and &1.process_started)) == 2
    assert_receive {:runtime_request, %{run_id: "/root/child:2", messages: child_history}}, 2_000
    assert Enum.any?(child_history, &(text(&1) =~ "first task"))
    assert Enum.any?(child_history, &(text(&1) =~ "second task"))

    # The real Codex.Session/manager survive turn completion, but the old root
    # Conversation is retired. A new root gets a new runtime identity.
    context = %{
      ctx.context
      | messages: [%{role: :assistant, parts: [%Synapsis.Part.Text{content: "previous"}]}]
    }

    :ok = SessionAdapter.prompt(adapter, context, "next turn")
    assert_receive {:runtime_started, 1, next_id}, 2_000
    assert next_id != run_id
    # Listing in a fresh root retains the existing child identity.
    assert_receive {:runtime_event, 1, ^next_id, %{type: :run_completed}}, 10_000
    assert [%{agent_id: child_id}] = roster.agents
    assert [%{agent_id: ^child_id}] = SessionAdapter.snapshot(adapter).agents
  end

  test "nested children have real parent identities and complete through the mailbox", ctx do
    script = fn request ->
      count = length(calls(request.messages))

      cond do
        String.starts_with?(request.run_id, "/root/child/grandchild") ->
          [completed("grandchild result")]

        String.starts_with?(request.run_id, "/root/child") and count == 0 ->
          tool(
            "spawn_agent",
            %{"task_name" => "grandchild", "message" => "nested", "fork_turns" => "none"},
            0
          )

        String.starts_with?(request.run_id, "/root/child") and count == 1 ->
          tool("wait_agent", %{"timeout_ms" => 10_000}, 1)

        String.starts_with?(request.run_id, "/root/child") ->
          [completed("nested child finished")]

        count == 0 ->
          tool(
            "spawn_agent",
            %{"task_name" => "child", "message" => "nest", "fork_turns" => "none"},
            0
          )

        count == 1 ->
          tool("wait_agent", %{"timeout_ms" => 10_000}, 1)

        true ->
          [completed("root finished")]
      end
    end

    adapter = start_adapter(ctx, script)
    SessionAdapter.prompt(adapter, ctx.context, "nested chain")
    assert_receive {:runtime_started, 1, id}, 2_000
    assert_receive {:runtime_event, 1, ^id, %{type: :run_completed}}, 10_000
    agents = SessionAdapter.snapshot(adapter).agents

    assert Enum.any?(
             agents,
             &(&1.name == "/root/child/grandchild" and &1.parent_name == "/root/child" and
                 &1.status == :completed)
           )
  end

  test "child permission uses exact runtime interaction and an authenticated host grant", ctx do
    script = fn request ->
      child? = String.starts_with?(request.run_id, "/root/")

      case {child?, length(calls(request.messages))} do
        {true, 0} ->
          tool(Write.name(), %{}, 0)

        {true, _} ->
          [completed("approved child")]

        {false, 0} ->
          tool(
            "spawn_agent",
            %{"task_name" => "writer", "message" => "write", "fork_turns" => "none"},
            0
          )

        {false, 1} ->
          tool("wait_agent", %{"timeout_ms" => 10_000}, 1)

        _ ->
          [completed("root finished")]
      end
    end

    context = %{ctx.context | agent: Map.put(ctx.context.agent, :tools, [Write.name()])}
    adapter = start_adapter(ctx, script)
    SessionAdapter.prompt(adapter, context, "permission chain")
    assert_receive {:runtime_started, 1, id}, 2_000

    assert_receive {:runtime_event, 1, ^id,
                    %{
                      type: :interaction_requested,
                      interaction_id: interaction,
                      request: request,
                      child: %{name: "/root/writer"}
                    }},
                   5_000

    assert request.kind == :tool_permission
    assert request.run_id == "/root/writer:1"
    SessionAdapter.resolve(adapter, "unrelated", true)
    assert [_] = SessionAdapter.snapshot(adapter).pending
    SessionAdapter.resolve(adapter, interaction, true)
    assert_receive {:runtime_event, 1, ^id, %{type: :run_completed}}, 10_000
    assert [] == SessionAdapter.snapshot(adapter).pending
  end

  test "native collaboration ask permits only the authenticated allow decision", ctx do
    collaboration_approval(ctx, true)
  end

  test "native collaboration ask denial has no child intent", ctx do
    collaboration_approval(ctx, false)
  end

  test "a child followup retains original denies after a new root expands its policy", ctx do
    script = fn request ->
      count = length(calls(request.messages))
      child? = String.starts_with?(request.run_id, "/root/")
      followup? = Enum.any?(request.messages, &(text(&1) in ["expanded root", "try write"]))

      cond do
        child? and followup? and count == 0 ->
          tool(Write.name(), %{}, 0)

        child? ->
          [completed("child finished")]

        followup? and count == 0 ->
          tool("followup_task", %{"target" => "child", "message" => "try write"}, 0)

        count == 0 ->
          tool(
            "spawn_agent",
            %{"task_name" => "child", "message" => "initial", "fork_turns" => "none"},
            0
          )

        count == 1 ->
          tool("wait_agent", %{"timeout_ms" => 10_000}, 1)

        true ->
          [completed("root finished")]
      end
    end

    snapshot = %{ctx.context.policy_snapshot | capability_overrides: %{Write.name() => :deny}}

    context = %{
      ctx.context
      | agent: Map.put(ctx.context.agent, :tools, [Write.name()]),
        policy_snapshot: snapshot
    }

    adapter = start_adapter(ctx, script)
    SessionAdapter.prompt(adapter, context, "original root")
    assert_receive {:runtime_started, 1, first}, 2_000
    assert_receive {:runtime_event, 1, ^first, %{type: :run_completed}}, 5_000

    expanded = %{
      context
      | policy_snapshot: PolicySnapshot.from_permission_mode("yolo", session_id: ctx.id)
    }

    SessionAdapter.prompt(adapter, expanded, "expanded root")
    assert_receive {:runtime_started, 1, second}, 2_000
    assert_receive {:runtime_event, 1, ^second, %{type: :run_completed}}, 5_000
    state = :sys.get_state(adapter)
    assert {:ok, record} = Synapsis.Agent.Runtime.Store.load(state.store, "/root/child:2")
    messages = get_in(record, [:run, :context, :conversation, :messages])
    assert Enum.any?(messages, &match?(%{role: :tool, result: %{is_error: true}}, &1))

    assert state.runs["/root/child:2"].context.policy_snapshot.capability_overrides[Write.name()] ==
             :deny

    refute_receive {:runtime_event, 1, _, %{type: :interaction_requested}}, 50
  end

  test "root-only owner loss persists uncertainty and blocks provider replay", ctx do
    test_pid = self()

    script = fn _ ->
      Stream.resource(
        fn ->
          send(test_pid, {:root_provider, self()})
          nil
        end,
        fn state ->
          receive do
            :finish -> {[completed("done")], state}
          after
            30_000 -> {:halt, state}
          end
        end,
        fn _ -> :ok end
      )
    end

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, adapter} =
      SessionAdapter.start_link(
        session_id: ctx.id,
        epoch: 1,
        owner: owner,
        provider: Provider,
        provider_context: %{script: script, test_pid: self()}
      )

    Process.unlink(adapter)
    SessionAdapter.prompt(adapter, ctx.context, "root only")
    assert_receive {:root_provider, provider_pid}, 3_000
    assert {:ok, %{root: %{status: :running}}} = Synapsis.Runtime.Store.get_projection(ctx.id)
    ref = Process.monitor(adapter)
    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^adapter, :normal}, 10_000
    refute Process.alive?(provider_pid)

    assert {:ok, %{root: %{status: :unknown_outcome}}} =
             Synapsis.Runtime.Store.get_projection(ctx.id)

    replacement = start_adapter(ctx, fn _ -> flunk("root must not replay") end)
    SessionAdapter.prompt(replacement, ctx.context, "retry")
    assert_receive {:runtime_admission_failed, 1, :recovery_required}, 2_000
    assert SessionAdapter.snapshot(replacement).recovery_required
  end

  test "root projection failure closes owners before admission and never calls provider", ctx do
    previous = Application.get_env(:synapsis_data, :runtime_store_adapter)
    Application.put_env(:synapsis_data, :runtime_store_adapter, FailProjection)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:synapsis_data, :runtime_store_adapter, previous),
        else: Application.delete_env(:synapsis_data, :runtime_store_adapter)
    end)

    adapter = start_adapter(ctx, fn _ -> flunk("projection failure must prevent dispatch") end)
    SessionAdapter.prompt(adapter, ctx.context, "must not start")
    assert_receive {:runtime_admission_failed, 1, %{class: :execution_failure}}, 5_000
    refute_receive {:runtime_started, _, _}, 50
    refute_receive {:runtime_request, _}, 50
    assert :sys.get_state(adapter).session == nil
  end

  test "selected unavailable tools fail admission without dispatching a provider", ctx do
    adapter = start_adapter(ctx, fn _ -> flunk("provider must not start") end)

    context = %{
      ctx.context
      | agent: Map.put(ctx.context.agent, :tools, ["unregistered-runtime-fixture"])
    }

    SessionAdapter.prompt(adapter, context, "fail closed")
    assert_receive {:runtime_admission_failed, 1, %{class: :unsupported_capability}}, 2_000
    refute_receive {:runtime_request, _}, 50
  end

  test "bounded discovery keeps the current selected catalog and does not load deferred tools",
       ctx do
    script = fn request ->
      if calls(request.messages) == [],
        do: tool("tool_search", %{"query" => "write"}, 0),
        else: [completed("searched")]
    end

    context = %{
      ctx.context
      | agent: Map.put(ctx.context.agent, :tools, ["tool_search", Write.name()])
    }

    adapter = start_adapter(ctx, script)
    SessionAdapter.prompt(adapter, context, "discover")
    assert_receive {:runtime_started, 1, id}, 2_000
    assert_receive {:runtime_history, 1, ^id, history}, 5_000
    assert Enum.any?(history, &(text(&1) =~ Write.name()))
    assert_receive {:runtime_event, 1, ^id, %{type: :run_completed}}, 1_000
  end

  test "native collaboration honors explicit deny before child admission", ctx do
    script = fn request ->
      if calls(request.messages) == [],
        do: tool("spawn_agent", %{"task_name" => "denied", "message" => "work"}, 0),
        else: [completed("denied safely")]
    end

    snapshot = %{ctx.context.policy_snapshot | capability_overrides: %{"spawn_agent" => :deny}}
    adapter = start_adapter(ctx, script)
    SessionAdapter.prompt(adapter, %{ctx.context | policy_snapshot: snapshot}, "deny spawn")
    assert_receive {:runtime_started, 1, id}, 2_000
    assert_receive {:runtime_history, 1, ^id, history}, 5_000
    assert Enum.any?(history, &match?(%{role: :tool, result: %{is_error: true}}, &1))
    assert_receive {:runtime_event, 1, ^id, %{type: :run_completed}}, 1_000
    assert [] == SessionAdapter.snapshot(adapter).agents
    assert {:ok, []} == Synapsis.Runtime.Store.list_facts(ctx.id, :admission_intent)
  end

  test "capacity refusal has no second intent and cancellation waits for child cleanup", ctx do
    test_pid = self()

    script = fn request ->
      if String.starts_with?(request.run_id, "/root/") do
        Stream.resource(
          fn ->
            send(test_pid, {:capacity_child, self()})
            nil
          end,
          fn state ->
            receive do
              :finish -> {[completed("done")], state}
            after
              30_000 -> {:halt, state}
            end
          end,
          fn _ -> :ok end
        )
      else
        case length(calls(request.messages)) do
          0 ->
            tool(
              "spawn_agent",
              %{"task_name" => "first", "message" => "wait", "fork_turns" => "none"},
              0
            )

          1 ->
            tool(
              "spawn_agent",
              %{"task_name" => "second", "message" => "refuse", "fork_turns" => "none"},
              1
            )

          _ ->
            [completed("capacity checked")]
        end
      end
    end

    adapter = start_adapter(Map.put(ctx, :limit, 2), script)
    SessionAdapter.prompt(adapter, ctx.context, "capacity")
    assert_receive {:runtime_started, 1, id}, 2_000
    assert_receive {:capacity_child, child_provider}, 3_000
    assert_receive {:runtime_history, 1, ^id, history}, 5_000
    assert Enum.any?(history, &match?(%{role: :tool, result: %{is_error: true}}, &1))
    assert_receive {:runtime_event, 1, ^id, %{type: :run_completed}}, 1_000
    assert {:ok, [_]} = Synapsis.Runtime.Store.list_facts(ctx.id, :admission_intent)
    SessionAdapter.cancel(adapter)

    assert_receive {:runtime_event, 1, ^id,
                    %{type: :run_cancelled, cleanup: {:ok, %{status: :confirmed}}}},
                   10_000

    refute Process.alive?(child_provider)
  end

  test "cancel before prompt confirms no runtime effects and emits one terminal", ctx do
    adapter = start_adapter(ctx, fn _ -> flunk("cancelled admission must not dispatch") end)
    SessionAdapter.cancel(adapter)

    assert_receive {:runtime_event, 1, nil,
                    %{type: :run_cancelled, cleanup: {:ok, %{status: :confirmed}}}},
                   1_000

    SessionAdapter.cancel(adapter)
    refute_receive {:runtime_event, 1, nil, %{type: :run_cancelled}}, 50
    refute_receive {:runtime_request, _}, 50
  end

  test "cancellation retains completed tool use and result before a blocked provider", ctx do
    test_pid = self()

    script = fn request ->
      if calls(request.messages) == [] do
        tool("list_agents", %{}, 0)
      else
        Stream.resource(
          fn ->
            send(test_pid, {:blocked_after_tool, self()})
            nil
          end,
          fn state ->
            receive do
              :finish -> {[completed("done")], state}
            after
              30_000 -> {:halt, state}
            end
          end,
          fn _ -> :ok end
        )
      end
    end

    adapter = start_adapter(ctx, script)
    SessionAdapter.prompt(adapter, ctx.context, "tool then wait")
    assert_receive {:runtime_started, 1, id}, 2_000
    assert_receive {:blocked_after_tool, provider_pid}, 5_000
    SessionAdapter.cancel(adapter)

    assert_receive {:runtime_event, 1, ^id,
                    %{
                      type: :run_cancelled,
                      cleanup: {:ok, %{status: :confirmed}},
                      messages: messages
                    }},
                   10_000

    assert [%{id: "call-0", name: "list_agents"}] = calls(messages)
    assert Enum.any?(messages, &match?(%{role: :tool, tool_call_id: "call-0"}, &1))
    refute Process.alive?(provider_pid)
    refute :sys.get_state(adapter).busy
    refute_receive {:runtime_event, 1, ^id, %{type: :run_cancelled}}, 50
  end

  test "fatal initial prompt rejection closes the runtime and emits a terminal failure", ctx do
    adapter = start_adapter(ctx, fn _ -> flunk("invalid prompt must not dispatch") end)
    SessionAdapter.prompt(adapter, ctx.context, "")
    assert_receive {:runtime_started, 1, id}, 2_000

    assert_receive {:runtime_event, 1, ^id,
                    %{
                      type: :run_failed,
                      error: %{class: :validation, message: "prompt must not be empty"},
                      cleanup: {:ok, %{status: :confirmed}},
                      messages: []
                    }},
                   10_000

    refute :sys.get_state(adapter).busy
    assert {:ok, %{root: %{status: :errored}}} = Synapsis.Runtime.Store.get_projection(ctx.id)
    refute_receive {:runtime_request, _}, 50
    refute_receive {:runtime_event, 1, ^id, %{type: :run_cancelled}}, 50
  end

  test "unavailable canonical history keeps the restart recovery fence", ctx do
    adapter = start_adapter(ctx, fn _ -> [completed("finished")] end)
    SessionAdapter.prompt(adapter, ctx.context, "complete")
    assert_receive {:runtime_started, 1, id}, 2_000
    assert_receive {:runtime_event, 1, ^id, %{type: :run_completed}}, 5_000

    previous = Application.get_env(:synapsis_data, :runtime_store_adapter)
    Application.put_env(:synapsis_data, :runtime_store_adapter, FailRuntimeRead)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:synapsis_data, :runtime_store_adapter, previous),
        else: Application.delete_env(:synapsis_data, :runtime_store_adapter)
    end)

    SessionAdapter.cancel(adapter)
    assert_receive {:runtime_event, 1, ^id, %{type: :storage_failed}}, 10_000

    assert {:ok, %{root: %{status: :unknown_outcome}, recovery_required: true}} =
             Synapsis.Runtime.Store.get_projection(ctx.id)

    stop_supervised!(SessionAdapter)
    replacement = start_adapter(ctx, fn _ -> flunk("missing history must not replay") end)
    SessionAdapter.prompt(replacement, ctx.context, "retry")
    assert_receive {:runtime_admission_failed, 1, :recovery_required}, 2_000
  end

  test "an intent without a receipt blocks a new generation without replay", ctx do
    :ok =
      Synapsis.Runtime.Store.put_fact(ctx.id, :admission_intent, "uncertain", %{
        attempt_id: "uncertain"
      })

    adapter = start_adapter(ctx, fn _ -> flunk("uncertain admission must not replay") end)
    SessionAdapter.prompt(adapter, ctx.context, "retry")
    assert_receive {:runtime_admission_failed, 1, :recovery_required}, 2_000
  end

  test "owner loss stops runtime owners and never replays persisted active children", ctx do
    test_pid = self()

    script = fn request ->
      if String.starts_with?(request.run_id, "/root/") do
        Stream.resource(
          fn ->
            send(test_pid, {:child_provider, self()})
            nil
          end,
          fn state ->
            receive do
              :finish -> {[completed("done")], state}
            after
              30_000 -> {:halt, state}
            end
          end,
          fn _ -> :ok end
        )
      else
        if calls(request.messages) == [],
          do:
            tool(
              "spawn_agent",
              %{"task_name" => "slow", "message" => "wait", "fork_turns" => "none"},
              0
            ),
          else: [completed("parent done")]
      end
    end

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, adapter} =
      SessionAdapter.start_link(
        session_id: ctx.id,
        epoch: 1,
        owner: owner,
        provider: Provider,
        provider_context: %{script: script, test_pid: self()}
      )

    Process.unlink(adapter)
    SessionAdapter.prompt(adapter, ctx.context, "start")
    assert_receive {:child_provider, provider_pid}, 5_000
    runtime = :sys.get_state(adapter)
    monitor = Process.monitor(adapter)
    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^adapter, :normal}, 15_000
    refute Process.alive?(provider_pid)
    refute Process.alive?(runtime.manager)
    refute Process.alive?(runtime.session)
    replacement = start_adapter(ctx, fn _ -> flunk("must not replay") end)
    SessionAdapter.prompt(replacement, ctx.context, "retry")
    assert_receive {:runtime_admission_failed, 1, :recovery_required}, 2_000
  end

  defp collaboration_approval(ctx, decision) do
    script = fn request ->
      cond do
        String.starts_with?(request.run_id, "/root/") ->
          [completed("child done")]

        calls(request.messages) == [] ->
          tool(
            "spawn_agent",
            %{"task_name" => "child", "message" => "work", "fork_turns" => "none"},
            0
          )

        decision and length(calls(request.messages)) == 1 ->
          tool("wait_agent", %{"timeout_ms" => 10_000}, 1)

        true ->
          [completed("root done")]
      end
    end

    snapshot = %{ctx.context.policy_snapshot | capability_overrides: %{"spawn_agent" => :ask}}
    adapter = start_adapter(ctx, script)
    SessionAdapter.prompt(adapter, %{ctx.context | policy_snapshot: snapshot}, "ask spawn")
    assert_receive {:runtime_started, 1, id}, 2_000

    assert_receive {:runtime_event, 1, ^id,
                    %{
                      type: :interaction_requested,
                      interaction_id: interaction,
                      request: %{tool_name: "spawn_agent"},
                      child: %{name: "/root"}
                    }},
                   3_000

    assert {:ok, []} == Synapsis.Runtime.Store.list_facts(ctx.id, :admission_intent)
    SessionAdapter.resolve(adapter, interaction, decision)
    assert_receive {:runtime_event, 1, ^id, %{type: :run_completed}}, 5_000
    {:ok, intents} = Synapsis.Runtime.Store.list_facts(ctx.id, :admission_intent)
    assert length(intents) == if(decision, do: 1, else: 0)
  end

  defp start_adapter(ctx, script) do
    start_supervised!(
      {SessionAdapter,
       session_id: ctx.id,
       epoch: 1,
       owner: self(),
       max_concurrent_threads_per_session: ctx[:limit] || 4,
       provider: Provider,
       provider_context: %{script: script, test_pid: self()}}
    )
  end

  defp completed(text),
    do: %{type: :response_completed, message: %{role: :assistant, content: text}}

  defp tool(name, arguments, index) do
    call = %{type: :tool_call, id: "call-#{index}", name: name, arguments: arguments}

    [
      %{type: :tool_call_completed, tool_call: Map.delete(call, :type)},
      %{type: :response_completed, message: %{role: :assistant, content: [call]}}
    ]
  end

  defp calls(messages),
    do:
      for(
        %{role: :assistant, content: blocks} <- messages,
        is_list(blocks),
        %{type: :tool_call} = block <- blocks,
        do: block
      )

  defp text(%{content: content}) when is_binary(content), do: content

  defp text(%{content: blocks}) when is_list(blocks),
    do: Enum.map_join(blocks, "", &Map.get(&1, :text, ""))

  defp text(%{result: %{content: content}}) when is_binary(content), do: content
  defp text(_), do: ""
end
