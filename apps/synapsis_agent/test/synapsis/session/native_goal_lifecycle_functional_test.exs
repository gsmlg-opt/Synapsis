defmodule Synapsis.Session.NativeGoalLifecycleFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Conversation, Goal, GoalBridge}
  alias Backplane.AgentRuntime.Goal.State
  alias Backplane.AgentRuntime.Store, as: NativeStore
  alias Synapsis.Agent.Runtime.{GoalStore, ProviderAdapter, RunInventory, Store}
  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Runtime.Store, as: Journal
  alias Synapsis.Session.{DynamicSupervisor, Worker}
  alias Synapsis.Session.Worker.PendingInputs

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @execution %{
    version: 1,
    mode: :execution,
    source: :user_mode,
    selected_mode: "bypass_permissions"
  }
  @default %{version: 1, mode: :execution, source: :default, selected_mode: nil}
  @call_ids ~w(goal-spawn goal-wait-one goal-followup goal-wait-two)
  @projection_fields ~w(thread_id run_id incarnation mode expected_goal_id root_thread_id root_goal_id)a
  @fact_fields ~w(version session_id namespace run_id incarnation thread_id mode_provenance mode expected_goal_id root_thread_id root_goal_id provenance)a
  @goal_tools ~w(create_goal get_goal update_goal)

  test "real owner accounts root and native child incarnations once and reloads settled history",
       %{
         tmp_dir: tmp_dir
       } do
    harness = setup_session(tmp_dir, ~w(spawn_agent wait_agent followup_task))
    id = harness.session.id
    seeded = seed_existing_goal(id)
    trace = trace_lifecycle(id)
    SessionHarness.ensure_running!(id)
    select_mode(id, harness, "bypass_permissions")

    assert :ok = Worker.send_message(id, "goal first root")
    assert_receive {:run_event, %{type: "session.completed"}}, 25_000
    await_selection_ready(id, System.monotonic_time(:millisecond) + 5_000)
    {worker, first_data, first} = runtime(id)
    assert is_pid(first.goal)
    assert first.context.mode_provenance == @execution
    assert first.goal_binding.run_id == first.run_id
    assert_goal_accounting(first.goal, id, seeded.goal.goal_id, 4)
    assert {:ok, first_locators} = Journal.list_facts(id, :run_locator)
    assert length(first_locators) == 2

    assert [%{name: "/root/child", incarnation: 1, status: :completed}] =
             Worker.snapshot(id).subagents.agents

    assert :ok = Worker.send_message(id, "goal execution root")
    assert_receive {:run_event, %{type: "session.completed"}}, 25_000
    await_selection_ready(id, System.monotonic_time(:millisecond) + 5_000)
    {^worker, second_data, second} = runtime(id)
    assert second_data.runtime_pid == first_data.runtime_pid
    assert second.goal == first.goal
    assert second.run_id != first.run_id
    assert second.goal_binding.capability != first.goal_binding.capability
    assert_goal_accounting(second.goal, id, seeded.goal.goal_id, 8)

    assert [%{name: "/root/child", incarnation: 2, status: :completed}] =
             Worker.snapshot(id).subagents.agents

    assert {:ok, locators} = Journal.list_facts(id, :run_locator)
    assert length(locators) == 4
    assert Enum.all?(first_locators, &(&1 in locators))

    assert Enum.find(locators -- first_locators, &(&1.kind == :child)).parent_run_id ==
             second.run_id

    assert_run_contexts(second, locators)
    assert_attribution_facts(id, locators, seeded.goal.goal_id, @execution)
    assert_tool_history(id)
    old_aggregates = load_aggregates(locators)
    assert_terminal_outboxes(old_aggregates)
    assert_tool_effects(old_aggregates, 4)
    old_messages = Synapsis.Sessions.get_messages(id)
    assert {:ok, old_intents} = Journal.list_facts(id, :admission_intent)
    assert {:ok, old_receipts} = Journal.list_facts(id, :admission_receipt)
    assert {:ok, old_facts} = Journal.list_facts(id, :goal_attribution)
    assert {:ok, old_goal_record} = GoalStore.load(:local, id)
    before_recreation = requests(harness)
    assert length(before_recreation) == 8
    assert Enum.count(before_recreation, fn {phase, _, _} -> phase == :child_first end) == 1
    assert Enum.count(before_recreation, fn {phase, _, _} -> phase == :child_followup end) == 1

    stop_settled(id, worker, second_data.runtime_pid, second.session, second.goal)
    assert {:ok, ^old_goal_record} = GoalStore.load(:local, id)
    assert load_aggregates(locators) == old_aggregates
    assert Synapsis.Sessions.get_messages(id) == old_messages
    SessionHarness.ensure_running!(id)
    assert :ok = Worker.send_message(id, "goal recreated root")
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    await_selection_ready(id, System.monotonic_time(:millisecond) + 5_000)
    {new_worker, new_data, recreated} = runtime(id)
    assert new_worker != worker
    assert new_data.runtime_pid != second_data.runtime_pid
    assert recreated.goal != second.goal
    assert recreated.store.namespace != second.store.namespace
    assert recreated.run_id not in [first.run_id, second.run_id]
    assert recreated.goal_binding.capability != second.goal_binding.capability
    assert recreated.goal_recovery[:diagnostic] in [nil, :none]
    assert_goal_accounting(recreated.goal, id, seeded.goal.goal_id, 9)
    assert {:ok, final_locators} = Journal.list_facts(id, :run_locator)
    assert Enum.all?(locators, &(&1 in final_locators))
    assert [fresh_locator] = final_locators -- locators
    assert fresh_locator.kind == :root
    assert_attribution_facts(id, final_locators, seeded.goal.goal_id, @execution)
    assert load_aggregates(locators) == old_aggregates
    assert Enum.take(Synapsis.Sessions.get_messages(id), length(old_messages)) == old_messages
    assert {:ok, ^old_intents} = Journal.list_facts(id, :admission_intent)
    assert {:ok, ^old_receipts} = Journal.list_facts(id, :admission_receipt)
    assert {:ok, final_facts} = Journal.list_facts(id, :goal_attribution)
    assert Enum.all?(old_facts, &(&1 in final_facts))
    assert {:ok, final_goal_record} = GoalStore.load(:local, id)

    assert Map.take(final_goal_record.receipts, Map.keys(old_goal_record.receipts)) ==
             old_goal_record.receipts

    assert requests(harness) ==
             before_recreation ++ [{:root_recreated, @call_ids, "goal recreated complete"}]

    assert_tool_history(id)
    assert_terminal_outboxes(load_aggregates(final_locators))
    assert_tool_effects(load_aggregates([fresh_locator]), 0)
    events = observed(trace)
    assert_startups(events, final_locators, seeded.goal.goal_id)

    assert_root_ownership(events, final_locators, %{
      first.store.namespace => first_data.runtime_pid,
      recreated.store.namespace => new_data.runtime_pid
    })

    assert_native_receipts(events, final_locators, final_goal_record)
  end

  test "production startup delivers and durably ACKs a valid terminal component outbox before dispatch",
       %{
         tmp_dir: tmp_dir
       } do
    harness = setup_session(tmp_dir, [])
    id = harness.session.id
    seeded = seed_existing_goal(id)
    {locator, fact, original, receipts} = terminal_component(id, seeded.goal.goal_id)
    trace = trace_lifecycle(id)
    SessionHarness.ensure_running!(id)
    assert :ok = Worker.send_message(id, "goal default root")
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    await_selection_ready(id, System.monotonic_time(:millisecond) + 5_000)
    {_worker, data, adapter} = runtime(id)
    assert is_pid(adapter.goal)
    assert adapter.goal_recovery[:diagnostic] in [nil, :none]
    assert adapter.roster.recovery_required == false
    assert {:ok, recovered} = Journal.load(locator.namespace, locator.run_id)
    assert recovered.revision == original.revision + 1
    assert recovered.incarnation == original.incarnation
    assert recovered.run.expected_revision == original.run.expected_revision + 1
    assert recovered.run.state == :completed
    assert recovered.run.outcome == original.run.outcome

    assert recovered.run.context.conversation ==
             %{original.run.context.conversation | goal_outbox: []}

    assert recovered.effects == original.effects
    assert recovered.outbox == original.outbox

    assert Map.drop(recovered.run, [:expected_revision, :context]) ==
             Map.drop(original.run, [:expected_revision, :context])

    assert {:ok, ^locator} = Journal.get_fact(id, :run_locator, identity(locator))
    assert {:ok, ^fact} = Journal.get_fact(id, :goal_attribution, identity(locator))
    assert_goal_accounting(adapter.goal, id, seeded.goal.goal_id, 2)
    assert requests(harness) == [{:root_default, [], "goal default complete"}]
    assert {:ok, record} = GoalStore.load(:local, id)
    for receipt <- receipts, do: assert(Map.has_key?(record.receipts, receipt.receipt_id))
    assert {:ok, locators} = Journal.list_facts(id, :run_locator)
    assert length(locators) == 2
    events = observed(trace)
    assert_startups(events, locators -- [locator], seeded.goal.goal_id)
    assert_recovery_order(events, locator, receipts, original, recovered, data.runtime_pid)
  end

  test "production startup recovers nested descendant usage with original receipts and current terminal fence",
       %{
         tmp_dir: tmp_dir
       } do
    harness = setup_session(tmp_dir, [])
    id = harness.session.id
    seeded = seed_existing_goal(id)
    [root, child, grandchild] = terminal_descendants_component(id, seeded.goal.goal_id)
    retained = [root, child, grandchild]
    old_messages = Synapsis.Sessions.get_messages(id)
    assert child.locator.parent_run_id == root.locator.run_id
    assert grandchild.locator.parent_run_id == child.locator.run_id
    assert child.fact.parent_attribution == root_projection(root.fact)
    assert grandchild.fact.parent_attribution == root_projection(child.fact)
    assert child.original.incarnation == 2
    assert child.locator.incarnation == 1
    assert child.fact.incarnation == 1
    assert Enum.all?(child.receipts, &(&1.incarnation == 1))
    trace = trace_lifecycle(id)
    SessionHarness.ensure_running!(id)
    assert :ok = Worker.send_message(id, "goal default root")
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    await_selection_ready(id, System.monotonic_time(:millisecond) + 5_000)
    {worker, data, adapter} = runtime(id)
    assert adapter.goal_recovery[:diagnostic] in [nil, :none]
    assert adapter.roster.recovery_required == false
    assert_goal_accounting(adapter.goal, id, seeded.goal.goal_id, 4)
    assert requests(harness) == [{:root_default, [], "goal default complete"}]
    assert {:ok, locators} = Journal.list_facts(id, :run_locator)
    assert length(locators) == 4
    assert [fresh_locator] = locators -- Enum.map(retained, & &1.locator)
    assert fresh_locator.kind == :root
    assert Enum.take(Synapsis.Sessions.get_messages(id), length(old_messages)) == old_messages
    assert {:ok, record} = GoalStore.load(:local, id)

    recovered =
      for fixture <- retained, into: %{} do
        %{locator: locator, fact: fact, original: original} = fixture
        assert {:ok, ^locator} = Journal.get_fact(id, :run_locator, identity(locator))
        assert {:ok, ^fact} = Journal.get_fact(id, :goal_attribution, identity(locator))
        assert_serializable(fact)
        assert {:ok, aggregate} = Journal.load(locator.namespace, locator.run_id)
        assert aggregate.revision == original.revision + 1
        assert aggregate.incarnation == original.incarnation
        assert aggregate.run.expected_revision == original.run.expected_revision + 1
        assert aggregate.run.state == :completed

        assert aggregate.run.context.conversation ==
                 %{original.run.context.conversation | goal_outbox: []}

        assert aggregate.effects == original.effects
        assert aggregate.outbox == original.outbox

        assert Map.drop(aggregate.run, [:expected_revision, :context]) ==
                 Map.drop(original.run, [:expected_revision, :context])

        for receipt <- fixture.receipts,
            do: assert(Map.has_key?(record.receipts, receipt.receipt_id))

        {locator, aggregate}
      end

    assert_tool_effects(recovered, 0)
    assert_terminal_outboxes(load_aggregates(locators))
    assert_tool_effects(load_aggregates([fresh_locator]), 0)
    events = observed(trace)
    assert_startups(events, [fresh_locator], seeded.goal.goal_id)
    assert length(calls(events, Conversation, :start_link)) == 1
    assert_native_receipts(events, locators, record)
    assert_nested_recovery_order(events, retained, recovered, data.runtime_pid, adapter.goal)
    stop_settled(id, worker, data.runtime_pid, adapter.session, adapter.goal)
    assert {:ok, ^record} = GoalStore.load(:local, id)
    assert load_aggregates(Enum.map(retained, & &1.locator)) == recovered
  end

  defp setup_session(tmp_dir, tools) do
    # Sessions.create starts Worker immediately. Persist this existing Session
    # fixture first so Goal and terminal journal records precede the first boot.
    :ok = Synapsis.Session.Store.ensure_started()
    {:ok, counter} = Agent.start_link(fn -> %{provider_requests: [], tool_executions: 0} end)
    provider = DeterministicProvider.start!(install?: false, counter: counter)
    agent_name = "goal_agent_#{System.unique_integer([:positive, :monotonic])}"

    {:ok, agent_config} =
      Synapsis.AgentConfigs.create(%{
        name: agent_name,
        label: "Goal lifecycle",
        provider: provider.name,
        model: "characterization-model",
        tools: tools,
        tool_contract_version: 1,
        permission_mode: "yolo",
        config: %{"workspace_path" => tmp_dir}
      })

    now = DateTime.utc_now()

    session = %Synapsis.Session{
      id: Ecto.UUID.generate(),
      agent: agent_name,
      provider: provider.name,
      model: "characterization-model",
      config: %{"memory_context" => false},
      inserted_at: now,
      updated_at: now
    }

    assert :ok = Synapsis.Session.Store.put_meta(session.id, Synapsis.Session.to_meta(session))

    assert {:ok, _} =
             Synapsis.Tool.Permission.update_config(
               session.id,
               Synapsis.Tool.Permission.config_for_mode("yolo")
               |> Map.put(:tool_contract_version, 1)
             )

    assert Registry.lookup(Synapsis.Session.Registry, session.id) == []

    harness = %{
      session: session,
      agent_config: agent_config,
      agent_name: agent_name,
      provider: provider,
      tool_name: nil,
      counter: counter,
      tmp_dir: tmp_dir
    }

    on_exit(fn ->
      SessionHarness.cleanup!(harness)
      cleanup_runtime(harness.session.id)
      Concord.Turso.delete("coord/goals/threads/" <> harness.session.id, timeout: 5_000)
    end)

    install_provider(harness)
    SessionHarness.subscribe!(harness.session.id)
    harness
  end

  defp seed_existing_goal(id) do
    # Explicit fixture for an already existing unbudgeted objective. An ordinary
    # prompt neither creates a Goal nor grants host mutation provenance.
    assert {:ok, empty} = State.new(id, [])
    assert {:ok, created} = State.create(empty, %{objective: "Verify ordinary native lifecycle"})
    assert {:ok, committed} = GoalStore.compare_and_swap(:local, id, 0, nil, created)
    assert committed.goal.token_budget == nil
    assert committed.goal.tokens_used == 0
    committed
  end

  defp assert_goal_accounting(goal, id, goal_id, provider_attempts) do
    assert {:ok, response} = Goal.get(goal)
    assert {:ok, record} = GoalStore.load(:local, id)
    assert record.goal.goal_id == goal_id
    assert response.goal.thread_id == id
    assert response.goal.status == :active
    assert response.goal.token_budget == nil
    assert response.goal.tokens_used == provider_attempts * (7 - 2 + 3)
    assert record.goal.tokens_used == response.goal.tokens_used
    assert record.accounting_uncertain == false
    assert map_size(record.usage.reports) == provider_attempts

    assert record.usage.totals == %{
             input_tokens: provider_attempts * 7,
             cached_tokens: provider_attempts * 2,
             output_tokens: provider_attempts * 3,
             reasoning_tokens: 0
           }
  end

  defp assert_attribution_facts(id, locators, goal_id, mode) do
    assert {:ok, facts} = Journal.list_facts(id, :goal_attribution)
    assert length(facts) == length(locators)

    for locator <- locators do
      assert {:ok, fact} = Journal.get_fact(id, :goal_attribution, identity(locator))

      fields =
        if locator.kind == :child, do: @fact_fields ++ [:parent_attribution], else: @fact_fields

      assert Enum.sort(Map.keys(fact)) == Enum.sort(fields)
      assert_serializable(fact)
      assert fact.version == 1
      assert fact.session_id == id
      assert fact.namespace == locator.namespace
      assert fact.run_id == locator.run_id
      assert fact.incarnation == locator.incarnation
      assert fact.mode_provenance == mode
      assert fact.mode == mode.mode
      assert fact.expected_goal_id == goal_id
      # Existing locator schema is immutable and gains no Goal fields.
      assert Enum.sort(Map.keys(locator)) ==
               Enum.sort(
                 ~w(version session_id namespace run_id incarnation kind name parent_run_id agent_id mode_provenance)a
               )

      if locator.kind == :root do
        assert fact.thread_id == id
        assert fact.provenance == :bound_root
        assert fact.root_thread_id == nil
        assert fact.root_goal_id == nil
      else
        assert fact.thread_id == locator.run_id
        assert fact.provenance == :intended_child
        assert fact.root_thread_id == id
        assert fact.root_goal_id == goal_id
        assert Enum.sort(Map.keys(fact.parent_attribution)) == Enum.sort(@projection_fields)

        assert fact.parent_attribution == %{
                 thread_id: id,
                 run_id: locator.parent_run_id,
                 incarnation: 1,
                 mode: mode.mode,
                 expected_goal_id: goal_id,
                 root_thread_id: nil,
                 root_goal_id: nil
               }
      end
    end
  end

  defp assert_serializable(value) when is_map(value) do
    assert not is_struct(value)
    refute Enum.any?([:capability, :authority, :usage_authoritative], &Map.has_key?(value, &1))

    for {key, item} <- value do
      assert_serializable(key)
      assert_serializable(item)
    end
  end

  defp assert_serializable(value) when is_list(value),
    do: Enum.each(value, &assert_serializable/1)

  defp assert_serializable(value),
    do: assert(is_nil(value) or is_atom(value) or is_number(value) or is_binary(value))

  defp assert_terminal_outboxes(aggregates) do
    for {_locator, aggregate} <- aggregates do
      assert aggregate.run.state == :completed
      assert get_in(aggregate.run, [:context, :conversation, :goal_outbox]) == []
    end
  end

  defp assert_tool_effects(aggregates, expected) do
    assert Enum.sum(
             for {_locator, aggregate} <- aggregates do
               aggregate.run
               |> Map.get(:execution_intents, %{})
               |> Map.values()
               |> Enum.count(&(&1.type == :tool))
             end
           ) == expected
  end

  defp select_mode(id, harness, mode) do
    await_selection_ready(id, System.monotonic_time(:millisecond) + 5_000)
    assert :ok = Worker.switch_mode(id, mode)
    assert {:ok, meta} = Synapsis.Session.Store.get_meta(id)

    assert meta.config == %{
             "memory_context" => false,
             "user_mode" => mode
           }

    assert {:ok, reloaded} = Synapsis.Sessions.get(id)
    assert reloaded.config == meta.config
    assert :ok = Worker.switch_agent(id, harness.agent_name)
    assert Worker.snapshot(id).session.config == meta.config
  end

  defp await_selection_ready(id, deadline) do
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    {state, data} = :sys.get_state(worker, 1_000)

    if state == :idle and data.pending_inputs.booted and not data.runtime_active and
         not PendingInputs.changing_agent?(data) do
      :ok
    else
      if System.monotonic_time(:millisecond) < deadline do
        receive do
        after
          10 -> await_selection_ready(id, deadline)
        end
      else
        flunk("Worker did not finish its ordinary selection readiness lane")
      end
    end
  end

  defp install_provider(harness) do
    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      users = for message <- request["messages"], message["role"] == "user", do: text(message)

      phase =
        cond do
          "goal recreated root" in users -> :root_recreated
          "goal execution root" in users -> :root_execution
          "goal child followup" in users -> :child_followup
          "goal child first" in users -> :child_first
          "goal first root" in users -> :root_first
          "goal default root" in users -> :root_default
        end

      ids =
        for message <- request["messages"],
            message["role"] == "tool" and message["tool_call_id"] in @call_ids,
            do: message["tool_call_id"]

      response =
        case {phase, ids} do
          {:root_first, []} ->
            {"spawn_agent", "goal-spawn",
             %{
               "task_name" => "child",
               "message" => "goal child first",
               "fork_turns" => "none"
             }}

          {:root_first, ["goal-spawn"]} ->
            {"wait_agent", "goal-wait-one", %{"timeout_ms" => 10_000}}

          {:root_first, ["goal-spawn", "goal-wait-one"]} ->
            "goal first complete"

          {:child_first, []} ->
            "goal child first complete"

          {:root_execution, ["goal-spawn", "goal-wait-one"]} ->
            {"followup_task", "goal-followup",
             %{
               "target" => "child",
               "message" => "goal child followup"
             }}

          {:root_execution, ["goal-spawn", "goal-wait-one", "goal-followup"]} ->
            {"wait_agent", "goal-wait-two", %{"timeout_ms" => 10_000}}

          {:root_execution, @call_ids} ->
            "goal execution complete"

          {:child_followup, []} ->
            "goal child followup complete"

          {:root_recreated, @call_ids} ->
            "goal recreated complete"

          {:root_default, []} ->
            "goal default complete"
        end

      Agent.update(harness.counter, fn state ->
        Map.update(
          state,
          :goal_requests,
          [{phase, ids, response}],
          &(&1 ++ [{phase, ids, response}])
        )
      end)

      respond(conn, response)
    end)
  end

  defp respond(conn, {name, id, arguments}),
    do:
      DeterministicProvider.send_sse(conn, [
        DeterministicProvider.tool_call_chunk(name, id, arguments),
        DeterministicProvider.finish_chunk("tool_calls"),
        usage_chunk()
      ])

  defp respond(conn, answer),
    do:
      DeterministicProvider.send_sse(conn, [
        DeterministicProvider.text_chunk(answer),
        DeterministicProvider.finish_chunk("stop"),
        usage_chunk()
      ])

  defp assert_tool_history(id) do
    parts = for message <- Synapsis.Sessions.get_messages(id), part <- message.parts, do: part

    assert for(%ToolUse{} = part <- parts, do: {part.tool, part.tool_use_id}) ==
             Enum.zip(~w(spawn_agent wait_agent followup_task wait_agent), @call_ids)

    assert for(%ToolResult{} = part <- parts, do: {part.tool_use_id, part.is_error}) ==
             Enum.map(@call_ids, &{&1, false})
  end

  defp assert_run_contexts(adapter, locators) do
    for locator <- locators do
      assert adapter.runs[locator.run_id].context.mode_provenance == locator.mode_provenance

      assert {:ok, ^locator} =
               Journal.get_fact(locator.session_id, :run_locator, identity(locator))
    end
  end

  defp load_aggregates(locators),
    do:
      Map.new(locators, fn locator ->
        assert {:ok, aggregate} = Journal.load(locator.namespace, locator.run_id)
        {locator, aggregate}
      end)

  defp runtime(id) do
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    {_status, data} = :sys.get_state(worker)
    adapter = if is_pid(data.runtime_pid), do: :sys.get_state(data.runtime_pid)
    {worker, data, adapter}
  end

  defp stop_settled(id, worker, adapter, native, goal) do
    monitored = for pid <- [worker, adapter, native, goal], do: {pid, Process.monitor(pid)}
    assert :ok = DynamicSupervisor.stop_session(id)

    for {pid, ref} <- monitored do
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 10_000
      assert reason in [:normal, :shutdown]
    end
  end

  defp terminal_component(id, goal_id) do
    assert {:ok, context} = Store.new(1)
    run_id = Ecto.UUID.generate()
    locator = RunInventory.root(id, context, run_id, @default)
    # The fixture owner creates no host instruction, admission or idle callback.
    # This unused Host context is not evidence of production Host execution.
    assert {:ok, goal} =
             Goal.start_link(
               thread_id: id,
               owner_pid: self(),
               store: GoalStore,
               store_context: :local,
               host: Synapsis.Session.Worker.GoalHost,
               host_context: %{session_id: id}
             )

    assert {:ok, binding} =
             Goal.bind(goal, %{
               thread_id: id,
               run_id: run_id,
               incarnation: 1,
               mode: :execution,
               authority: %{run_id: run_id},
               usage_authoritative: false
             })

    assert {:ok, attributed} = Goal.attribution(goal, binding)
    assert attributed.expected_goal_id == goal_id

    fact =
      Map.merge(root_projection(attributed), %{
        version: 1,
        session_id: id,
        namespace: context.namespace,
        mode_provenance: @default,
        provenance: :bound_root
      })

    assert :ok = RunInventory.retain(locator)
    assert :ok = Journal.put_fact(id, :goal_attribution, identity(locator), fact)
    run = %{run_id: run_id, incarnation: 1, expected_revision: 0, state: :queued}
    run = commit_component(context, run, {:admit, 1, %{}})
    run = commit_component(context, run, {:start, 2})
    messages = [%{role: :assistant, content: "retained terminal component complete"}]
    conversation = %{turn_id: Ecto.UUID.generate(), messages: messages, goal_outbox: []}

    events = [
      {:turn_started, %{mode: :execution, trigger: :user}},
      {:usage,
       %{
         identity: "component-attempt",
         attempt_id: "component-attempt",
         input_tokens: 7,
         cached_tokens: 2,
         output_tokens: 3,
         reasoning_tokens: 0,
         cumulative: false
       }},
      {:item_completed, %{kind: :assistant, text: "retained terminal component complete"}},
      {:turn_stopped, %{reason: :completed}}
    ]

    conversation = GoalBridge.queue(%{goal_binding: attributed, run: run}, conversation, events)
    receipts = conversation.goal_outbox
    assert length(receipts) == 4
    assert Enum.all?(receipts, &(&1.expected_goal_id == goal_id and &1.run_id == run_id))

    run =
      commit_component(
        context,
        run,
        {:conversation_updated, 3, %{run_id: run_id, incarnation: 1, conversation: conversation}}
      )

    run =
      commit_component(
        context,
        run,
        {:finish, 4,
         %{
           run_id: run_id,
           incarnation: 1,
           status: :completed,
           outcome: %{answer: "retained terminal component complete"}
         }}
      )

    assert {:ok, original} = Journal.load(context.namespace, run_id)
    assert original.run == run
    assert original.run.context.conversation.goal_outbox == receipts
    assert {:ok, :unbound} = Goal.unbind(goal, binding)
    ref = Process.monitor(goal)
    assert :ok = GenServer.stop(goal, :normal, 5_000)
    assert_receive {:DOWN, ^ref, :process, ^goal, :normal}, 5_000
    assert {:ok, record} = GoalStore.load(:local, id)
    assert record.goal.tokens_used == 0
    assert record.receipts == %{}
    {locator, fact, original, receipts}
  end

  defp terminal_descendants_component(id, goal_id) do
    {locator, fact, original, receipts} = terminal_component(id, goal_id)
    context = %{namespace: locator.namespace, incarnation: locator.incarnation}
    # This owner only issues valid fixture capabilities. Production startup below
    # owns recovery; no Host callback, live delegation or replay is simulated.
    assert {:ok, goal} =
             Goal.start_link(
               thread_id: id,
               owner_pid: self(),
               store: GoalStore,
               store_context: :local,
               host: Synapsis.Session.Worker.GoalHost,
               host_context: %{session_id: id}
             )

    assert {:ok, binding} =
             Goal.bind(goal, %{
               thread_id: id,
               run_id: locator.run_id,
               incarnation: locator.incarnation,
               mode: :execution,
               authority: %{run_id: locator.run_id},
               usage_authoritative: false
             })

    assert {:ok, attributed} = Goal.attribution(goal, binding)
    assert root_projection(attributed) == root_projection(fact)

    root = %{
      locator: locator,
      fact: fact,
      original: original,
      receipts: receipts,
      binding: binding
    }

    {descendants, _parent} =
      Enum.map_reduce(["/root/child", "/root/child/grandchild"], attributed, fn name, parent ->
        identity = %{
          run_id: Ecto.UUID.generate(),
          incarnation: 1,
          name: name,
          agent_id: Ecto.UUID.generate()
        }

        locator = RunInventory.child(id, context, identity, parent.run_id, @default)
        # Closed intended provenance is retained before native delegation. The
        # oracle is explicit; no production GoalLifecycle fact/plan helper is used.
        fact = %{
          version: 1,
          session_id: id,
          namespace: context.namespace,
          run_id: identity.run_id,
          incarnation: 1,
          thread_id: identity.run_id,
          mode_provenance: @default,
          mode: :execution,
          expected_goal_id: goal_id,
          root_thread_id: id,
          root_goal_id: goal_id,
          provenance: :intended_child,
          parent_attribution: root_projection(parent)
        }

        assert Enum.sort(Map.keys(fact)) == Enum.sort(@fact_fields ++ [:parent_attribution])
        assert_serializable(fact)
        assert :ok = RunInventory.retain(locator)
        assert :ok = Journal.put_fact(id, :goal_attribution, identity(locator), fact)

        assert {:ok, binding} =
                 Goal.delegate(goal, parent, %{
                   thread_id: identity.run_id,
                   run_id: identity.run_id,
                   incarnation: 1,
                   authority: %{run_id: identity.run_id}
                 })

        assert {:ok, attributed} = Goal.attribution(goal, binding)
        assert root_projection(attributed) == root_projection(fact)
        {original, receipts} = terminal_descendant(context, attributed)

        fixture = %{
          locator: locator,
          fact: fact,
          original: original,
          receipts: receipts,
          binding: binding
        }

        {fixture, attributed}
      end)

    for fixture <- Enum.reverse([root | descendants]) do
      assert {:ok, :unbound} = Goal.unbind(goal, fixture.binding)
    end

    ref = Process.monitor(goal)
    assert :ok = GenServer.stop(goal, :normal, 5_000)
    assert_receive {:DOWN, ^ref, :process, ^goal, :normal}, 5_000
    assert {:ok, record} = GoalStore.load(:local, id)
    assert record.goal.tokens_used == 0
    assert record.receipts == %{}
    [child, grandchild] = descendants

    # A successful public fence of an already completed aggregate is a positive
    # store fixture, not a crash, restart, lost-ACK or nonterminal qualification.
    assert {:ok, fenced} =
             NativeStore.fence(
               Store,
               context,
               child.locator.run_id,
               child.original.revision,
               1,
               2
             )

    assert {:ok, fenced_child} = Journal.load(context.namespace, child.locator.run_id)
    assert fenced_child.run == fenced.run
    assert fenced_child.revision == child.original.revision + 1
    assert fenced_child.incarnation == 2
    assert fenced_child.run.incarnation == 2

    assert Map.drop(fenced_child.run, [:expected_revision, :incarnation]) ==
             Map.drop(child.original.run, [:expected_revision, :incarnation])

    assert fenced_child.effects == child.original.effects
    assert fenced_child.outbox == child.original.outbox
    [root, %{child | original: fenced_child}, grandchild]
  end

  defp terminal_descendant(context, binding) do
    run_id = binding.run_id
    run = %{run_id: run_id, incarnation: 1, expected_revision: 0, state: :queued}
    run = commit_component(context, run, {:admit, 1, %{}})
    run = commit_component(context, run, {:start, 2})
    answer = "retained descendant #{run_id} complete"

    conversation = %{
      turn_id: Ecto.UUID.generate(),
      messages: [%{role: :assistant, content: answer}],
      goal_outbox: []
    }

    events = [
      {:turn_started, %{mode: :execution, trigger: :user}},
      {:usage,
       %{
         identity: run_id <> ":component-attempt",
         attempt_id: "component-attempt",
         input_tokens: 7,
         cached_tokens: 2,
         output_tokens: 3,
         reasoning_tokens: 0,
         cumulative: false
       }},
      {:item_completed, %{kind: :assistant, text: answer}},
      {:turn_stopped, %{reason: :completed}}
    ]

    conversation = GoalBridge.queue(%{goal_binding: binding, run: run}, conversation, events)
    assert [receipt] = conversation.goal_outbox
    assert receipt.type == :usage
    assert receipt.thread_id == run_id
    assert receipt.run_id == run_id
    assert receipt.incarnation == 1
    assert receipt.expected_goal_id == binding.root_goal_id
    assert receipt.payload == elem(Enum.at(events, 1), 1)

    run =
      commit_component(
        context,
        run,
        {:conversation_updated, 3, %{run_id: run_id, incarnation: 1, conversation: conversation}}
      )

    run =
      commit_component(
        context,
        run,
        {:finish, 4,
         %{run_id: run_id, incarnation: 1, status: :completed, outcome: %{answer: answer}}}
      )

    assert {:ok, original} = Journal.load(context.namespace, run_id)
    assert original.run == run
    assert original.run.context.conversation.goal_outbox == [receipt]
    {original, [receipt]}
  end

  defp commit_component(context, run, command) do
    assert {:ok, staged} = NativeStore.stage(Store, context, run, %{command: command})

    assert {:ok, %{revision: revision}} =
             NativeStore.acknowledge_commit(Store, context, staged.stage, %{})

    assert revision == run.expected_revision + 1
    assert {:ok, aggregate} = Journal.load(context.namespace, run.run_id)
    assert aggregate.revision == revision
    aggregate.run
  end

  defp root_projection(binding),
    do: Map.new(@projection_fields, &{&1, Map.get(binding, &1)})

  defp trace_lifecycle(id) do
    modules = [
      Journal,
      RunInventory,
      Conversation,
      Goal,
      GoalBridge,
      NativeStore,
      ProviderAdapter
    ]

    for module <- modules, do: Code.ensure_loaded!(module)
    trace = :trace.session_create(:goal_lifecycle286, self(), [])
    on_exit(fn -> :trace.session_destroy(trace) end)

    :trace.function(trace, {Journal, :put_fact, 4}, [{[id, :_, :_, :_], [], [{:return_trace}]}], [
      :local
    ])

    for {module, function, arity} <- [
          {Conversation, :start_link, 1},
          {Goal, :bind, 2},
          {Goal, :delegate, 3},
          {Goal, :unbind, 2},
          {Goal, :committed, 2},
          {GoalBridge, :deliver, 3},
          {NativeStore, :stage, 4},
          {NativeStore, :acknowledge_commit, 4},
          {Journal, :load, 2},
          {RunInventory, :load, 1},
          {ProviderAdapter, :stream, 2}
        ] do
      :trace.function(trace, {module, function, arity}, [{:_, [], [{:return_trace}]}], [:local])
    end

    :trace.process(trace, :all, true, [:call, :monotonic_timestamp])
    trace
  end

  defp observed(trace) do
    barrier = :trace.delivered(trace, :all)
    assert_receive {:trace_delivered, :all, ^barrier}, 5_000
    drain([])
  end

  defp drain(events) do
    receive do
      {:trace_ts, pid, :call, {module, function, args}, at} ->
        drain([
          %{pid: pid, kind: :call, module: module, function: function, args: args, at: at}
          | events
        ])

      {:trace_ts, pid, :return_from, {module, function, arity}, result, at} ->
        drain([
          %{
            pid: pid,
            kind: :return,
            module: module,
            function: function,
            arity: arity,
            result: result,
            at: at
          }
          | events
        ])
    after
      0 -> Enum.sort_by(events, & &1.at)
    end
  end

  defp calls(events, module, function),
    do:
      Enum.filter(events, &(&1.kind == :call and &1.module == module and &1.function == function))

  defp returned(events, call) do
    result =
      Enum.find(events, fn event ->
        event.kind == :return and event.pid == call.pid and event.module == call.module and
          event.function == call.function and event.at > call.at
      end)

    assert is_map(result)
    result
  end

  defp startup(events, locator) do
    [event] =
      for event <- calls(events, Conversation, :start_link),
          [opts] = event.args,
          opts[:run_id] == locator.run_id and opts[:incarnation] == locator.incarnation and
            opts[:context].namespace == locator.namespace,
          do: event

    event
  end

  defp assert_startups(events, locators, goal_id) do
    for locator <- locators do
      event = startup(events, locator)
      [opts] = event.args
      assert is_pid(opts[:goal])
      assert opts[:goal_binding].expected_goal_id == goal_id
      assert opts[:goal_binding].run_id == locator.run_id
      assert opts[:goal_binding].incarnation == locator.incarnation
      assert opts[:goal_binding].mode == locator.mode_provenance.mode
      assert opts[:goal_binding].usage_authoritative == false
      assert opts[:host_context][:mode_provenance] == locator.mode_provenance

      assert opts[:thread_id] ==
               if(locator.kind == :root, do: locator.session_id, else: locator.run_id)

      assert opts[:goal_binding].thread_id == opts[:thread_id]

      assert MapSet.disjoint?(
               MapSet.new(Map.keys(opts[:registry].tools)),
               MapSet.new(@goal_tools)
             )

      if locator.kind == :child do
        assert opts[:goal_binding].root_thread_id == locator.session_id
        assert opts[:goal_binding].root_goal_id == goal_id
      end

      for kind <- [:run_locator, :goal_attribution] do
        retained =
          Enum.find(calls(events, Journal, :put_fact), fn write ->
            [session_id, fact_kind, key, _value] = write.args
            session_id == locator.session_id and fact_kind == kind and key == identity(locator)
          end)

        assert is_map(retained)
        acknowledged = returned(events, retained)
        assert acknowledged.result == :ok
        assert acknowledged.at < event.at
      end

      unbind =
        Enum.find(calls(events, Goal, :unbind), &(&1.args == [opts[:goal], opts[:goal_binding]]))

      assert is_map(unbind)
      assert returned(events, unbind).result == {:ok, :unbound}
    end
  end

  defp assert_root_ownership(events, locators, owners) do
    roots = Enum.filter(locators, &(&1.kind == :root))
    bindings = calls(events, Goal, :bind)
    assert length(bindings) == length(roots)

    for locator <- roots do
      [opts] = startup(events, locator).args

      [bound] =
        Enum.filter(bindings, fn event ->
          [goal, attrs] = event.args
          goal == opts[:goal] and attrs.run_id == locator.run_id
        end)

      assert bound.pid == Map.fetch!(owners, locator.namespace)
      assert returned(events, bound).result == {:ok, opts[:goal_binding]}
    end

    delegates = calls(events, Goal, :delegate)
    children = Enum.filter(locators, &(&1.kind == :child))
    assert length(delegates) == length(children)

    for locator <- children do
      [opts] = startup(events, locator).args

      [delegated] =
        Enum.filter(delegates, fn event ->
          [_goal, _parent, attrs] = event.args
          attrs.run_id == locator.run_id and attrs.incarnation == locator.incarnation
        end)

      assert delegated.pid not in Map.values(owners)
      assert returned(events, delegated).result == {:ok, opts[:goal_binding]}
    end
  end

  defp assert_native_receipts(events, locators, record) do
    committed = calls(events, Goal, :committed)
    receipts = for event <- committed, [_goal, receipt] = event.args, do: receipt
    assert receipts != []

    assert MapSet.new(Map.keys(record.receipts)) ==
             MapSet.new(Enum.map(receipts, & &1.receipt_id))

    for event <- committed do
      assert {:ok, _response} = returned(events, event).result
      [_goal, receipt] = event.args

      locator =
        Enum.find(
          locators,
          &(&1.run_id == receipt.run_id and &1.incarnation == receipt.incarnation)
        )

      assert is_map(locator)

      assert receipt.thread_id ==
               if(locator.kind == :root, do: locator.session_id, else: locator.run_id)

      assert receipt.binding.mode == locator.mode_provenance.mode
      if locator.kind == :child, do: assert(receipt.type == :usage)

      accounted =
        receipt
        |> Map.delete(:binding)
        |> Map.put(:thread_id, locator.session_id)
        |> Map.update!(:payload, &Map.put(&1, :mode, locator.mode_provenance.mode))

      digest = :crypto.hash(:sha256, :erlang.term_to_binary(accounted)) |> Base.encode16()
      assert record.receipts[receipt.receipt_id] == digest
    end
  end

  defp assert_recovery_order(events, locator, receipts, original, recovered, adapter) do
    [delivery] =
      for event <- calls(events, GoalBridge, :deliver),
          [_goal, binding, exact] = event.args,
          binding.run_id == locator.run_id and exact == receipts,
          do: event

    assert {:ok, responses} = returned(events, delivery).result
    assert length(responses) == length(receipts)

    [staging] =
      for event <- calls(events, NativeStore, :stage),
          [Store, context, run, %{command: command}] = event.args,
          context.namespace == locator.namespace and run.run_id == locator.run_id,
          elem(command, 0) == :goal_outbox_acknowledged,
          do: event

    [Store, context, run, %{command: command}] = staging.args
    assert context.incarnation == original.incarnation
    assert run == original.run
    assert {:goal_outbox_acknowledged, _timestamp, identity_map} = command

    assert identity_map == %{
             run_id: locator.run_id,
             incarnation: original.incarnation,
             receipts: receipts
           }

    assert {:ok, staged} = returned(events, staging).result

    [commit] =
      Enum.filter(calls(events, NativeStore, :acknowledge_commit), fn event ->
        match?([Store, ^context, stage, _] when stage == staged.stage, event.args)
      end)

    acknowledged = returned(events, commit)
    assert {:ok, %{revision: revision}} = acknowledged.result
    assert revision == recovered.revision
    assert returned(events, delivery).at < staging.at
    assert staging.at < commit.at

    [binding_call] =
      Enum.filter(calls(events, Goal, :bind), fn event ->
        [_goal, attrs] = event.args
        attrs.run_id == locator.run_id
      end)

    assert binding_call.pid == adapter
    assert binding_call.at < delivery.at
    fresh_streams = calls(events, ProviderAdapter, :stream)
    assert length(fresh_streams) == 1
    [provider] = fresh_streams
    assert acknowledged.at < provider.at

    assert Enum.any?(calls(events, RunInventory, :load), fn event ->
             event.args == [locator.session_id] and event.at > acknowledged.at and
               returned(events, event).at < provider.at and
               match?(
                 {:ok, %{entries: entries}} when is_list(entries),
                 returned(events, event).result
               ) and
               Enum.any?(
                 elem(returned(events, event).result, 1).entries,
                 &(&1.locator == locator and &1.aggregate == recovered)
               )
           end)

    assert Enum.any?(calls(events, Journal, :load), fn event ->
             event.args == [locator.namespace, locator.run_id] and event.at > acknowledged.at and
               returned(events, event).result == {:ok, recovered} and
               returned(events, event).at < provider.at
           end)
  end

  defp assert_nested_recovery_order(events, retained, recovered, adapter, goal) do
    [provider] = calls(events, ProviderAdapter, :stream)
    [root | _] = retained
    assert length(calls(events, Goal, :bind)) == 4
    assert length(calls(events, Goal, :delegate)) == 2

    acknowledgements =
      for fixture <- retained do
        %{locator: locator, original: original, receipts: receipts} = fixture

        [delivery] =
          for event <- calls(events, GoalBridge, :deliver),
              [^goal, binding, exact] = event.args,
              binding.run_id == locator.run_id and exact == receipts,
              do: event

        [^goal, binding, ^receipts] = delivery.args
        assert root_projection(binding) == root_projection(fixture.fact)
        assert binding.capability != fixture.binding.capability
        assert binding.incarnation == locator.incarnation
        assert binding.usage_authoritative == false
        assert {:ok, responses} = returned(events, delivery).result
        assert length(responses) == length(receipts)
        function = if locator.kind == :root, do: :bind, else: :delegate

        [issued] =
          Enum.filter(calls(events, Goal, function), fn event ->
            returned(events, event).result == {:ok, binding}
          end)

        assert issued.pid == adapter
        assert returned(events, issued).at < delivery.at

        bindings =
          if locator.kind == :child do
            [^goal, parent, attrs] = issued.args
            assert attrs.run_id == locator.run_id
            assert attrs.incarnation == locator.incarnation
            assert root_projection(parent) == root_projection(root.fact)
            [binding, parent]
          else
            [binding]
          end

        [staging] =
          for event <- calls(events, NativeStore, :stage),
              [Store, context, run, %{command: {:goal_outbox_acknowledged, _, _}}] = event.args,
              context.namespace == locator.namespace and run.run_id == locator.run_id,
              do: event

        [Store, context, run, %{command: command}] = staging.args
        assert context == %{namespace: locator.namespace, incarnation: original.incarnation}
        assert run == original.run
        assert {:goal_outbox_acknowledged, _timestamp, identity_map} = command

        assert identity_map == %{
                 run_id: locator.run_id,
                 incarnation: original.incarnation,
                 receipts: receipts
               }

        assert {:ok, staged} = returned(events, staging).result

        [commit] =
          Enum.filter(calls(events, NativeStore, :acknowledge_commit), fn event ->
            match?([Store, ^context, stage, _] when stage == staged.stage, event.args)
          end)

        acknowledged = returned(events, commit)

        assert acknowledged.result ==
                 {:ok, %{revision: recovered[locator].revision, outbox: [], mode: :durable}}

        assert returned(events, delivery).at < staging.at
        assert returned(events, staging).at < commit.at
        assert acknowledged.at < provider.at

        for bound <- bindings do
          [unbind] = Enum.filter(calls(events, Goal, :unbind), &(&1.args == [goal, bound]))
          assert returned(events, unbind).result == {:ok, :unbound}
          assert acknowledged.at < unbind.at
          assert returned(events, unbind).at < provider.at
        end

        for receipt <- receipts do
          assert Enum.count(calls(events, Goal, :committed), fn event ->
                   [_goal, committed] = event.args

                   committed.receipt_id == receipt.receipt_id and
                     Map.delete(committed, :binding) == receipt
                 end) == 1
        end

        acknowledged.at
      end

    assert Enum.any?(calls(events, RunInventory, :load), fn event ->
             loaded = returned(events, event)

             event.args == [root.locator.session_id] and event.at > Enum.max(acknowledgements) and
               loaded.at < provider.at and
               match?({:ok, %{entries: entries}} when is_list(entries), loaded.result) and
               Enum.all?(recovered, fn {locator, aggregate} ->
                 Enum.any?(elem(loaded.result, 1).entries, fn entry ->
                   entry.locator == locator and entry.aggregate == aggregate
                 end)
               end)
           end)
  end

  defp usage_chunk do
    %{
      "choices" => [],
      "usage" => %{
        "prompt_tokens" => 7,
        "prompt_tokens_details" => %{"cached_tokens" => 2},
        "completion_tokens" => 3,
        "completion_tokens_details" => %{"reasoning_tokens" => 0},
        "total_tokens" => 10
      }
    }
  end

  defp cleanup_runtime(id) do
    {:ok, locators} = Journal.list_facts(id, :run_locator)

    prefixes =
      ["coord/runtime/facts/" <> segment(id) <> "/"] ++
        Enum.map(
          Enum.uniq_by(locators, & &1.namespace),
          &("coord/runtime/runs/" <> segment(&1.namespace) <> "/")
        )

    for prefix <- prefixes do
      {:ok, pairs} = Concord.Turso.prefix_scan(prefix, timeout: 5_000)
      for {key, _} <- pairs, do: Concord.Turso.delete(key, timeout: 5_000)
    end

    Concord.Turso.delete("coord/runtime/projections/" <> segment(id), timeout: 5_000)
  end

  defp identity(locator),
    do:
      Base.url_encode64(
        :erlang.term_to_binary({locator.namespace, locator.run_id, locator.incarnation}),
        padding: false
      )

  defp segment(value), do: value |> to_string() |> Base.url_encode64(padding: false)
  defp requests(harness), do: Agent.get(harness.counter, & &1.goal_requests)
  defp text(%{"content" => content}) when is_binary(content), do: content

  defp text(%{"content" => parts}) when is_list(parts),
    do: Enum.map_join(parts, &(&1["text"] || ""))

  defp text(_), do: ""
end
