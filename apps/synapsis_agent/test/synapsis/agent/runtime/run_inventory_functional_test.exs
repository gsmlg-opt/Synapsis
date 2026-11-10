defmodule Synapsis.Agent.Runtime.RunInventoryFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Backplane.AgentRuntime.Conversation
  alias Backplane.AgentRuntime.Store, as: NativeStore
  alias Synapsis.Agent.Runtime.{ProviderAdapter, RunInventory, Store}
  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Runtime.Store, as: Journal
  alias Synapsis.Session.{DynamicSupervisor, Worker}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @call_ids ~w(inventory-spawn inventory-wait-one inventory-followup inventory-wait-two)
  @tool_names ~w(spawn_agent wait_agent followup_task wait_agent)

  test "real Worker retains both roots and child incarnations before native startup and reloads without replay",
       %{tmp_dir: tmp_dir} do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: tmp_dir,
        install_provider?: false,
        session_config: %{"memory_context" => false}
      )

    {:ok, _} =
      Synapsis.AgentConfigs.update(harness.agent_config, %{
        tools: ~w(spawn_agent wait_agent followup_task)
      })

    id = harness.session.id

    on_exit(fn ->
      SessionHarness.cleanup!(harness)
      cleanup_runtime(id)
    end)

    install_provider(harness)
    trace_session = trace_inventory(id)
    SessionHarness.subscribe!(id)
    SessionHarness.ensure_running!(id)

    assert :ok = Worker.send_message(id, "inventory first root")
    assert_receive {:run_event, %{type: "session.completed"}}, 25_000
    {worker, adapter_pid, first} = runtime(id)
    first_root = first.run_id
    namespace = first.store.namespace
    assert first.initializing == false
    assert first.recovery_inventory == %{coverage: :retained_only, entries: []}

    assert [%{name: "/root/child", agent_id: agent_id, incarnation: 2, status: :completed}] =
             Worker.snapshot(id).subagents.agents

    first_locators = [
      %{
        version: 1,
        session_id: id,
        namespace: namespace,
        run_id: first_root,
        incarnation: 1,
        kind: :root,
        name: "/root",
        parent_run_id: nil,
        agent_id: nil,
        mode_provenance: %{version: 1, mode: :execution, source: :default, selected_mode: nil}
      },
      %{
        version: 1,
        session_id: id,
        namespace: namespace,
        run_id: "/root/child:1",
        incarnation: 1,
        kind: :child,
        name: "/root/child",
        parent_run_id: first_root,
        agent_id: agent_id,
        mode_provenance: %{version: 1, mode: :execution, source: :default, selected_mode: nil}
      },
      %{
        version: 1,
        session_id: id,
        namespace: namespace,
        run_id: "/root/child:2",
        incarnation: 2,
        kind: :child,
        name: "/root/child",
        parent_run_id: first_root,
        agent_id: agent_id,
        mode_provenance: %{version: 1, mode: :execution, source: :default, selected_mode: nil}
      }
    ]

    assert_facts(id, first_locators)
    assert_tool_history(id)
    {:ok, first_intents} = Journal.list_facts(id, :admission_intent)
    {:ok, first_receipts} = Journal.list_facts(id, :admission_receipt)

    assert Enum.sort(Enum.map(first_intents, &{&1.run_id, &1.incarnation})) ==
             [{"/root/child:1", 1}, {"/root/child:2", 2}]

    assert Enum.count(first_receipts, &(&1.status == :created and &1.process_started)) == 2
    assert root_tool_count(namespace, first_root) == 4

    assert :ok = Worker.send_message(id, "inventory second root")
    assert_receive {:run_event, %{type: "session.completed"}}, 15_000
    {^worker, ^adapter_pid, second} = runtime(id)
    second_root = second.run_id
    assert second_root != first_root
    assert second.store.namespace == namespace
    assert second.roster.root.run_id == second_root

    second_locator = %{
      version: 1,
      session_id: id,
      namespace: namespace,
      run_id: second_root,
      incarnation: 1,
      kind: :root,
      name: "/root",
      parent_run_id: nil,
      agent_id: nil,
      mode_provenance: %{version: 1, mode: :execution, source: :default, selected_mode: nil}
    }

    old_locators = first_locators ++ [second_locator]
    assert_facts(id, old_locators)
    assert {:ok, %{coverage: :retained_only, entries: entries}} = RunInventory.load(id)
    assert entries == stored_entries(old_locators)
    assert root_tool_count(namespace, second_root) == 0
    assert_tool_history(id)
    assert_request_log(harness, false)

    worker_monitor = Process.monitor(worker)
    adapter_monitor = Process.monitor(adapter_pid)
    native_monitor = Process.monitor(second.session)
    assert :ok = DynamicSupervisor.stop_session(id)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :shutdown}, 5_000
    assert_receive {:DOWN, ^adapter_monitor, :process, ^adapter_pid, adapter_reason}, 10_000
    assert adapter_reason in [:normal, :shutdown]
    assert_receive {:DOWN, ^native_monitor, :process, _, native_reason}, 10_000
    assert native_reason in [:normal, :shutdown]

    retained = %{coverage: :retained_only, entries: stored_entries(old_locators)}
    assert {:ok, ^retained} = RunInventory.load(id)
    before_recreation = System.monotonic_time()
    SessionHarness.ensure_running!(id)
    assert :ok = Worker.send_message(id, "inventory recreated root")
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    {new_worker, new_adapter_pid, recreated} = runtime(id)
    assert new_worker != worker
    assert new_adapter_pid != adapter_pid
    assert recreated.initializing == false
    assert recreated.recovery_inventory == retained
    assert recreated.store.namespace != namespace
    assert recreated.run_id not in [first_root, second_root]

    new_locator = %{
      version: 1,
      session_id: id,
      namespace: recreated.store.namespace,
      run_id: recreated.run_id,
      incarnation: 1,
      kind: :root,
      name: "/root",
      parent_run_id: nil,
      agent_id: nil,
      mode_provenance: %{version: 1, mode: :execution, source: :default, selected_mode: nil}
    }

    assert_facts(id, old_locators ++ [new_locator])
    assert stored_entries(old_locators) == retained.entries
    assert {:ok, final_inventory} = RunInventory.load(id)

    assert final_inventory == %{
             coverage: :retained_only,
             entries: stored_entries(old_locators ++ [new_locator])
           }

    assert {:ok, fresh_pairs} =
             Concord.Turso.prefix_scan(run_prefix(recreated.store.namespace), timeout: 5_000)

    assert Enum.map(fresh_pairs, &elem(&1, 0)) ==
             [run_prefix(recreated.store.namespace) <> segment(recreated.run_id)]

    assert {:ok, ^first_intents} = Journal.list_facts(id, :admission_intent)
    assert {:ok, ^first_receipts} = Journal.list_facts(id, :admission_receipt)
    assert root_tool_count(namespace, first_root) == 4
    assert root_tool_count(namespace, second_root) == 0
    assert root_tool_count(recreated.store.namespace, recreated.run_id) == 0
    assert_tool_history(id)
    assert_request_log(harness, true)

    observed = observed_calls(trace_session)
    assert_locator_order(observed, old_locators ++ [new_locator])
    assert_startup_load(observed, id, retained, new_locator, before_recreation)

    fresh_monitor = Process.monitor(new_worker)
    fresh_adapter_monitor = Process.monitor(new_adapter_pid)
    fresh_native_monitor = Process.monitor(recreated.session)
    assert :ok = DynamicSupervisor.stop_session(id)
    assert_receive {:DOWN, ^fresh_monitor, :process, ^new_worker, :shutdown}, 5_000

    assert_receive {:DOWN, ^fresh_adapter_monitor, :process, ^new_adapter_pid,
                    final_adapter_reason},
                   10_000

    assert final_adapter_reason in [:normal, :shutdown]
    assert_receive {:DOWN, ^fresh_native_monitor, :process, _, final_native_reason}, 10_000
    assert final_native_reason in [:normal, :shutdown]
  end

  test "exact root and child facts load full native aggregates across independent namespaces" do
    :ok = Synapsis.Session.Store.ensure_started()
    id = Ecto.UUID.generate()
    {:ok, first_store} = Store.new(1)
    {:ok, second_store} = Store.new(1)
    on_exit(fn -> cleanup_runtime(id, [first_store.namespace, second_store.namespace]) end)

    root = %{
      version: 1,
      session_id: id,
      namespace: first_store.namespace,
      run_id: "ordinary-root",
      incarnation: 1,
      kind: :root,
      name: "/root",
      parent_run_id: nil,
      agent_id: nil
    }

    child = %{
      version: 1,
      session_id: id,
      namespace: first_store.namespace,
      run_id: "/root/child:2",
      incarnation: 2,
      kind: :child,
      name: "/root/child",
      parent_run_id: "ordinary-root",
      agent_id: "ordinary-child-id"
    }

    other_root = %{root | namespace: second_store.namespace}

    assert RunInventory.root(id, first_store, "ordinary-root") == root
    assert RunInventory.root(id, second_store, "ordinary-root") == other_root

    assert RunInventory.child(
             id,
             first_store,
             %{
               run_id: "/root/child:2",
               incarnation: 2,
               name: "/root/child",
               agent_id: "ordinary-child-id"
             },
             "ordinary-root"
           ) == child

    for locator <- [other_root, child, root] do
      aggregate = admit_native_run(locator)
      assert :ok = RunInventory.retain(locator)
      assert :ok = RunInventory.retain(locator)
      assert {:ok, ^locator} = Journal.get_fact(id, :run_locator, locator_identity(locator))
      assert {:ok, ^aggregate} = Journal.load(locator.namespace, locator.run_id)
    end

    assert_facts(id, [root, child, other_root])

    assert {:ok, %{coverage: :retained_only, entries: entries}} = RunInventory.load(id)
    assert entries == stored_entries([root, child, other_root])
    assert Enum.map(entries, & &1.locator) == sort_locators([root, child, other_root])
  end

  defp install_provider(harness) do
    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      users = for message <- request["messages"], message["role"] == "user", do: text(message)

      phase =
        cond do
          "inventory recreated root" in users -> :root_recreated
          "inventory second root" in users -> :root_second
          "inventory child followup" in users -> :child_followup
          "inventory child first" in users -> :child_first
          "inventory first root" in users -> :root_first
        end

      call_ids =
        for message <- request["messages"],
            message["role"] == "tool" and message["tool_call_id"] in @call_ids,
            do: message["tool_call_id"]

      Agent.update(harness.counter, fn state ->
        Map.update(state, :inventory_requests, [{phase, call_ids, request}], fn requests ->
          requests ++ [{phase, call_ids, request}]
        end)
      end)

      case {phase, call_ids} do
        {:root_first, []} ->
          call(conn, "spawn_agent", "inventory-spawn", %{
            "task_name" => "child",
            "message" => "inventory child first",
            "fork_turns" => "none"
          })

        {:root_first, ["inventory-spawn"]} ->
          call(conn, "wait_agent", "inventory-wait-one", %{"timeout_ms" => 10_000})

        {:root_first, ["inventory-spawn", "inventory-wait-one"]} ->
          call(conn, "followup_task", "inventory-followup", %{
            "target" => "child",
            "message" => "inventory child followup"
          })

        {:root_first, ["inventory-spawn", "inventory-wait-one", "inventory-followup"]} ->
          call(conn, "wait_agent", "inventory-wait-two", %{"timeout_ms" => 10_000})

        {:root_first, @call_ids} ->
          answer(conn, "inventory first root complete")

        {:child_first, []} ->
          answer(conn, "inventory child first complete")

        {:child_followup, []} ->
          answer(conn, "inventory child followup complete")

        {:root_second, @call_ids} ->
          answer(conn, "inventory second root complete")

        {:root_recreated, @call_ids} ->
          answer(conn, "inventory recreated root complete")
      end
    end)
  end

  defp assert_request_log(harness, recreated?) do
    requests = Agent.get(harness.counter, & &1.inventory_requests)
    assert length(requests) == if(recreated?, do: 9, else: 8)

    roots =
      for {phase, ids, _} <- requests,
          phase in [:root_first, :root_second, :root_recreated],
          do: {phase, ids}

    expected_roots = [
      {:root_first, []},
      {:root_first, ["inventory-spawn"]},
      {:root_first, ["inventory-spawn", "inventory-wait-one"]},
      {:root_first, ["inventory-spawn", "inventory-wait-one", "inventory-followup"]},
      {:root_first, @call_ids},
      {:root_second, @call_ids}
    ]

    assert roots ==
             if(recreated?,
               do: expected_roots ++ [{:root_recreated, @call_ids}],
               else: expected_roots
             )

    children =
      for {phase, ids, request} <- requests,
          phase in [:child_first, :child_followup],
          do: {phase, ids, request}

    assert [{:child_first, [], _}, {:child_followup, [], followup}] = children
    users = for message <- followup["messages"], message["role"] == "user", do: text(message)
    assert users == ["inventory child first", "inventory child followup"]
    assert Enum.any?(followup["messages"], &(text(&1) == "inventory child first complete"))
  end

  defp assert_tool_history(id) do
    messages = Synapsis.Sessions.get_messages(id)
    parts = for message <- messages, part <- message.parts, do: part
    uses = for %ToolUse{} = part <- parts, do: part
    results = for %ToolResult{} = part <- parts, do: part
    assert Enum.map(uses, &{&1.tool, &1.tool_use_id}) == Enum.zip(@tool_names, @call_ids)
    assert Enum.map(results, & &1.tool_use_id) == @call_ids
    assert Enum.all?(results, &(&1.is_error == false))
  end

  defp root_tool_count(namespace, run_id) do
    assert {:ok, aggregate} = Journal.load(namespace, run_id)

    aggregate.run
    |> Map.get(:execution_intents, %{})
    |> Map.values()
    |> Enum.count(&(&1.type == :tool))
  end

  defp assert_facts(id, expected) do
    assert {:ok, facts} = Journal.list_facts(id, :run_locator)
    assert sort_locators(facts) == sort_locators(expected)

    for locator <- expected do
      assert {:ok, ^locator} = Journal.get_fact(id, :run_locator, locator_identity(locator))
    end
  end

  defp stored_entries(locators) do
    for locator <- sort_locators(locators) do
      assert {:ok, aggregate} = Journal.load(locator.namespace, locator.run_id)
      assert aggregate.run.run_id == locator.run_id
      assert aggregate.incarnation == locator.incarnation
      assert aggregate.run.incarnation == locator.incarnation
      assert aggregate.revision == aggregate.run.expected_revision
      assert is_map(aggregate.transition)
      assert is_list(aggregate.effects)
      assert is_list(aggregate.outbox)
      %{locator: locator, aggregate: aggregate, availability: :present}
    end
  end

  defp admit_native_run(locator) do
    run = %{
      run_id: locator.run_id,
      incarnation: locator.incarnation,
      expected_revision: 0,
      state: :queued
    }

    context = %{namespace: locator.namespace, incarnation: locator.incarnation}

    assert {:ok, %{revision: 1}} =
             NativeStore.store(Store, context, run, %{command: {:admit, 1, %{}}})

    expected_run = %{
      run_id: locator.run_id,
      incarnation: locator.incarnation,
      expected_revision: 1,
      state: :queued,
      admitted: true,
      input: %{},
      deadline: nil,
      outcome: nil,
      context: %{},
      active_provider: nil,
      current_step: nil,
      active_tools: %{},
      active_wait: nil,
      dependencies: [],
      settled_children: [],
      continuation_results: %{},
      tool_results: %{}
    }

    %{
      run: expected_run,
      transition: %{
        expected_revision: 1,
        state: :queued,
        events: [
          %{
            event_id: "",
            aggregate_id: "",
            sequence: 0,
            schema_version: 1,
            type: "run.admitted",
            occurred_at: 1,
            causation_id: nil,
            payload: %{"state" => :queued, "input" => %{}}
          }
        ]
      },
      effects: [],
      outbox: [],
      revision: 1,
      incarnation: locator.incarnation
    }
  end

  defp trace_inventory(id) do
    for module <- [Journal, Conversation, ProviderAdapter, RunInventory],
        do: Code.ensure_loaded!(module)

    session = :trace.session_create(:run_inventory176, self(), [])
    on_exit(fn -> :trace.session_destroy(session) end)

    :trace.function(
      session,
      {Journal, :put_fact, 4},
      [{[id, :run_locator, :_, :_], [], [{:return_trace}]}],
      [:local]
    )

    for mfa <- [
          {Journal, :load, 2},
          {Conversation, :start_link, 1},
          {ProviderAdapter, :stream, 2},
          {RunInventory, :load, 1}
        ] do
      :trace.function(session, mfa, [{:_, [], [{:return_trace}]}], [:local])
    end

    :trace.process(session, :all, true, [:call, :monotonic_timestamp])
    session
  end

  defp observed_calls(session) do
    barrier = :trace.delivered(session, :all)
    assert_receive {:trace_delivered, :all, ^barrier}, 5_000
    drain_calls([])
  end

  defp drain_calls(acc) do
    receive do
      {:trace_ts, pid, :call, {module, function, args}, at} ->
        drain_calls([
          %{pid: pid, kind: :call, module: module, function: function, args: args, at: at} | acc
        ])

      {:trace_ts, pid, :return_from, {module, function, arity}, result, at} ->
        drain_calls([
          %{
            pid: pid,
            kind: :return,
            module: module,
            function: function,
            arity: arity,
            result: result,
            at: at
          }
          | acc
        ])
    after
      0 -> Enum.sort_by(acc, & &1.at)
    end
  end

  defp assert_locator_order(observed, locators) do
    for locator <- locators do
      fact =
        Enum.find(observed, fn event ->
          event.kind == :call and event.module == Journal and event.function == :put_fact and
            event.args == [locator.session_id, :run_locator, locator_identity(locator), locator]
        end)

      assert is_map(fact)

      acknowledged =
        Enum.find(observed, fn event ->
          event.kind == :return and event.module == Journal and event.function == :put_fact and
            event.pid == fact.pid and event.at > fact.at
        end)

      assert acknowledged.result == :ok
      [startup] = native_startups(observed, locator)
      assert acknowledged.at < startup.at

      requests =
        for event <- observed,
            event.kind == :call and event.module == ProviderAdapter and event.function == :stream,
            [request, _] = event.args,
            request.run_id == locator.run_id and request.incarnation == locator.incarnation,
            do: event

      assert requests != []
      assert Enum.all?(requests, &(&1.at > acknowledged.at and &1.at > startup.at))
    end
  end

  defp native_startups(observed, locator) do
    for event <- observed,
        event.kind == :call and event.module == Conversation and event.function == :start_link,
        [opts] = event.args,
        opts[:run_id] == locator.run_id and opts[:incarnation] == locator.incarnation and
          opts[:context].namespace == locator.namespace,
        do: event
  end

  defp assert_startup_load(observed, id, expected, new_locator, after_at) do
    [startup] = native_startups(observed, new_locator)

    assert Enum.any?(observed, fn event ->
             event.kind == :call and event.module == RunInventory and event.function == :load and
               event.args == [id] and event.at >= after_at and event.at < startup.at and
               Enum.any?(observed, fn returned ->
                 returned.kind == :return and returned.module == RunInventory and
                   returned.function == :load and
                   returned.pid == event.pid and returned.at > event.at and
                   returned.at < startup.at and
                   returned.result == {:ok, expected}
               end)
           end)

    for entry <- expected.entries do
      assert Enum.any?(observed, fn event ->
               event.kind == :call and event.module == Journal and event.function == :load and
                 event.args == [entry.locator.namespace, entry.locator.run_id] and
                 event.at >= after_at and event.at < startup.at and
                 Enum.any?(observed, fn returned ->
                   returned.kind == :return and returned.module == Journal and
                     returned.function == :load and
                     returned.pid == event.pid and returned.at > event.at and
                     returned.at < startup.at and
                     returned.result == {:ok, entry.aggregate}
                 end)
             end)
    end
  end

  defp runtime(id) do
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    {_state, data} = :sys.get_state(worker)
    {worker, data.runtime_pid, :sys.get_state(data.runtime_pid)}
  end

  defp cleanup_runtime(id, extra_namespaces \\ []) do
    {:ok, locators} = Journal.list_facts(id, :run_locator)
    namespaces = Enum.uniq(extra_namespaces ++ Enum.map(locators, & &1.namespace))

    prefixes =
      ["coord/runtime/facts/" <> segment(id) <> "/"] ++ Enum.map(namespaces, &run_prefix/1)

    for prefix <- prefixes do
      {:ok, pairs} = Concord.Turso.prefix_scan(prefix, timeout: 5_000)
      for {key, _} <- pairs, do: Concord.Turso.delete(key, timeout: 5_000)
    end

    Concord.Turso.delete("coord/runtime/projections/" <> segment(id), timeout: 5_000)
  end

  defp locator_identity(locator),
    do:
      Base.url_encode64(
        :erlang.term_to_binary({locator.namespace, locator.run_id, locator.incarnation}),
        padding: false
      )

  defp sort_locators(locators),
    do: Enum.sort_by(locators, &{&1.namespace, &1.run_id, &1.incarnation})

  defp run_prefix(namespace), do: "coord/runtime/runs/" <> segment(namespace) <> "/"
  defp segment(value), do: value |> to_string() |> Base.url_encode64(padding: false)

  defp text(%{"content" => content}) when is_binary(content), do: content

  defp text(%{"content" => parts}) when is_list(parts),
    do: Enum.map_join(parts, &(&1["text"] || ""))

  defp text(_), do: ""

  defp call(conn, name, id, arguments),
    do:
      DeterministicProvider.send_sse(conn, [
        DeterministicProvider.tool_call_chunk(name, id, arguments),
        DeterministicProvider.finish_chunk("tool_calls")
      ])

  defp answer(conn, text),
    do:
      DeterministicProvider.send_sse(conn, [
        DeterministicProvider.text_chunk(text),
        DeterministicProvider.finish_chunk("stop")
      ])
end
