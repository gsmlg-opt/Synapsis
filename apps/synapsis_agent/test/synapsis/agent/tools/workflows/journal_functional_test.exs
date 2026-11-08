defmodule Synapsis.Agent.Tools.Workflows.JournalFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Conversation, Goal}
  alias Backplane.AgentRuntime.Codex
  alias Backplane.AgentRuntime.Codex.{CodeMode, Headless, ResourceRegistry, Session}
  alias Synapsis.Agent.Runtime.{GoalStore, RunInventory, SessionAdapter, Store}
  alias Synapsis.Agent.Tools.{Catalog, Filesystem, Policy, Profiles}
  alias Synapsis.Agent.Tools.CodeMode, as: HostCodeMode
  alias Synapsis.Agent.Tools.Workflows.{Effect, Journal}
  alias Synapsis.Runtime.Store, as: RuntimeStore
  alias Synapsis.Workflow.Continuations
  alias Synapsis.Workflow.Journal, as: CoreJournal
  alias Synapsis.Goal.Store, as: GoalDataStore
  alias Synapsis.Filesystem.Local
  alias Synapsis.Session.Store, as: SessionStore

  @moduletag :tmp_dir
  @moduletag timeout: 90_000
  @node "/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node"
  @caller_tool "fixture_workflow_journal"
  @source "// @exec: {\"yield_time_ms\": 1000}\nreturn await tools[input.tool_name](input.arguments);\n"
  @trace_targets [
    {Filesystem, :validate_prepared_receipt, 2},
    {Local, :prepare_target, 5},
    {Effect, :run, 2},
    {Journal, :create, 1},
    {Journal, :run, 3},
    {Journal, :reopen, 5},
    {Continuations, :create, 4},
    {Continuations, :load, 3},
    {Continuations, :commit, 5},
    {RuntimeStore, :put_fact, 4},
    {RuntimeStore, :get_fact, 3},
    {RuntimeStore, :load, 2},
    {Concord.Turso, :compare_and_swap, 3},
    {Concord.Turso, :txn, 2},
    {Filesystem, :execute, 1},
    {CodeMode.Worker, :start_link, 1},
    {ResourceRegistry, :fetch, 4},
    {Goal, :delegate, 3},
    {Goal, :unbind, 2},
    {Conversation, :emit, 2},
    {RunInventory, :retain, 1},
    {Session, :start_link, 1},
    {Session, :bind, 3},
    {Headless, :start_link, 1},
    {Headless, :execute, 3},
    {Headless, :status, 1},
    {Profiles, :build, 4},
    {Profiles, :project_catalog, 3},
    {ResourceRegistry, :register, 5},
    {ResourceRegistry, :release, 3},
    {CodeMode.Worker, :os_identity, 1},
    {Store, :store, 3}
  ]

  # This wrapper holds the genuine issued Profiles snapshot and delegates the
  # production handlers unchanged. Copies of returned states are observation
  # only: no prepared record, ticket, operation or authority is manufactured.
  # It does not exercise Worker/options admission or a production Workflow caller.
  defmodule AdapterHost do
    use GenServer

    def start_link(observer), do: GenServer.start_link(__MODULE__, observer)

    def init(observer) do
      {:ok,
       %{
         observer: observer,
         closing: false,
         error: nil,
         tool_contexts: %{},
         jobs: %{},
         owner_ref: Process.monitor(observer)
       }}
    end

    def handle_call({:install_root, key, snapshot}, _from, state) do
      entry = %{
        snapshot: snapshot,
        discovery: nil,
        prepared_targets: %{},
        prepared_target_bytes: 0,
        prepared_targets_closed?: false
      }

      {:reply, :ok, %{state | tool_contexts: %{key => entry}}}
    end

    def handle_call({:root_snapshot, key}, _from, state),
      do: {:reply, state.tool_contexts[key].snapshot, state}

    # Observe the actual production projection once, including its exact closure
    # return. Repeating project_catalog would manufacture new classifier closures.
    def handle_call({:tool_context, _, _} = message, from, state) do
      :erlang.trace(self(), true, [:call, {:tracer, state.observer}])

      reply =
        try do
          SessionAdapter.handle_call(message, from, state)
        after
          barrier = :erlang.trace_delivered(:all)

          receive do
            {:trace_delivered, :all, ^barrier} -> :ok
          after
            5_000 -> raise "production projection observation did not drain"
          end

          :erlang.trace(self(), false, [:call])
        end

      {:reply, result, next} = reply
      send(state.observer, {:adapter_call, message, elem(from, 0), result, next.tool_contexts})
      {:reply, result, next}
    end

    def handle_call(message, from, state) do
      {:reply, result, next} = SessionAdapter.handle_call(message, from, state)
      send(state.observer, {:adapter_call, message, elem(from, 0), result, next.tool_contexts})
      {:reply, result, next}
    end

    def handle_info(message, state) do
      {:noreply, next} = SessionAdapter.handle_info(message, state)
      {:noreply, next}
    end
  end

  # Only the harness caller is custom. Its operation, task, deadline, catalog,
  # authority and Session binding come from actual native parent admission.
  defmodule GoalHost do
    @behaviour Backplane.AgentRuntime.Goal.Host

    def record_user_instruction(observer, thread_id, instruction) do
      send(observer, {:goal_instruction, thread_id, instruction})
      :ok
    end

    def start_turn_if_idle(_, _, _), do: raise("this fixture uses native Headless admission")
  end

  defmodule StrictCallerBackend do
    def execute(operation) do
      context = operation.backend_context
      observer = context.observer
      trace(observer)

      key = {operation.run_id, operation.incarnation}
      snapshot = GenServer.call(context.adapter, {:root_snapshot, key}, 5_000)

      supplied =
        context
        |> Map.take([
          :session_binding,
          :profiles_context,
          :ceiling,
          :store,
          :session_id,
          :caller,
          :workflow_effect_registration
        ])
        |> Map.put(:profiles_snapshot, snapshot)
        |> Map.put(:operation, operation)

      case operation.arguments["effect"] do
        "reopen" -> read_in_fresh_task(operation, context)
        action -> write_occurrence(operation, action, supplied, context)
      end
    end

    defp write_occurrence(operation, action, supplied, context) do
      acknowledged =
        case action do
          "read" ->
            {:ok, record} = Journal.create(supplied)
            record

          "write" ->
            {:ok, record} =
              Continuations.load(context.session_id, operation.arguments["workflow_id"])

            record
        end

      request = request(acknowledged.id, action)
      result = Journal.run(acknowledged, request, supplied)
      {:ok, attribution} = Goal.attribution(context.goal, context.goal_binding)
      {:ok, durable_goal} = GoalDataStore.load(context.session_id)
      drain_trace()
      # Keep :procs enabled until the actual admitted backend task exits naturally.
      :erlang.trace(self(), false, [:call, :set_on_spawn])

      send(context.observer, {
        :journal_writer_result,
        self(),
        operation,
        acknowledged,
        result,
        attribution,
        durable_goal
      })

      case result do
        {:ok, %{record: record, effect: effect}} ->
          {:ok,
           %{
             value: %{
               "workflow_id" => record.id,
               "revision" => record.revision,
               "consumer_value" => effect.consumer_value
             },
             is_error: false
           }}

        error ->
          error
      end
    end

    defp read_in_fresh_task(operation, context) do
      workflow_id = operation.arguments["workflow_id"]
      revision = operation.arguments["revision"]

      task =
        Task.Supervisor.async_nolink(context.reader_supervisor, fn ->
          trace(context.observer)

          send(
            context.observer,
            {:journal_reader_ready, self(), operation, workflow_id, revision}
          )

          # Only the ordinary reader waits. Native effects are never suspended.
          # The observer releases this reader after actual writer :exit,:normal.
          receive do
            {:read_after_normal_writer, ^workflow_id, ^revision} -> :ok
          after
            10_000 -> raise "journal reader did not observe normal writer completion"
          end

          result =
            Journal.reopen(
              context.session_id,
              context.profiles_context.agent.id,
              workflow_id,
              revision,
              deadline: System.monotonic_time(:millisecond) + 15_000
            )

          drain_trace()
          :erlang.trace(self(), false, [:call, :set_on_spawn])
          send(context.observer, {:journal_reader_result, self(), operation, result})
          result
        end)

      result = Task.await(task, 25_000)
      drain_trace()
      :erlang.trace(self(), false, [:call, :set_on_spawn])

      case result do
        {:ok, %{record: record, entries: entries}} ->
          {:ok,
           %{
             value: %{
               "revision" => record.revision,
               "values" => Enum.map(entries, & &1.effect.consumer_value)
             },
             is_error: false
           }}

        error ->
          error
      end
    end

    defp request(workflow_id, action) do
      {request_id, target} =
        case action do
          "read" ->
            {"read:1",
             %{
               tool_name: "synapsis::read",
               tool_revision: 1,
               arguments: %{"path" => "input.txt"}
             }}

          "write" ->
            {"write:2",
             %{
               tool_name: "synapsis::write",
               tool_revision: 1,
               arguments: %{"path" => "output.txt", "content" => "one\nkeep\n"}
             }}
        end

      %{
        correlation: %{workflow_id: workflow_id, request_id: request_id, segment: 0},
        target: target,
        limits: %{
          timeout_ms: 15_000,
          effect_timeout_ms: 10_000,
          commit_timeout_ms: 5_000,
          cleanup_timeout_ms: 5_000,
          output_limit: 65_536,
          work: 4
        }
      }
    end

    defp trace(observer),
      do: :erlang.trace(self(), true, [:call, :procs, :set_on_spawn, {:tracer, observer}])

    defp drain_trace do
      barrier = :erlang.trace_delivered(:all)

      receive do
        {:trace_delivered, :all, ^barrier} -> :ok
      after
        5_000 -> raise "journal native observation did not drain"
      end
    end
  end

  test "one continuation settles two native effects and fresh readers consume exact durable evidence",
       %{tmp_dir: root} do
    File.write!(Path.join(root, "input.txt"), "workflow journal read\n")
    fixture = open_fixture(root)
    install_observation()

    :erlang.trace(fixture.parent, true, [:call, :procs, :set_on_spawn, {:tracer, self()}])

    assert {:ok, root_worker_supervisor} =
             ResourceRegistry.worker_supervisor(fixture.binding.resource_registry)

    :erlang.trace(root_worker_supervisor, true, [:call, :procs, :set_on_spawn, {:tracer, self()}])

    source = """
    // @exec: {"yield_time_ms": 10000}
    const read = await tools.fixture_workflow_journal({effect: "read"});
    const first = await tools.fixture_workflow_journal({effect: "reopen", workflow_id: read.value.workflow_id, revision: 3});
    const write = await tools.fixture_workflow_journal({effect: "write", workflow_id: read.value.workflow_id});
    const second = await tools.fixture_workflow_journal({effect: "reopen", workflow_id: write.value.workflow_id, revision: 5});
    return [read.value, first.value, write.value, second.value];
    """

    assert {:ok, %{run_id: run_id, incarnation: 1}} = Headless.execute(fixture.parent, source)
    assert run_id == fixture.identity.run_id

    {occurrences, observed} =
      Enum.map_reduce([3, 5], [], fn revision, observed ->
        assert_receive {
                         :journal_writer_result,
                         writer,
                         operation,
                         acknowledged,
                         {:ok, %{record: record, effect: effect}},
                         attribution,
                         durable_goal
                       },
                       40_000

        assert record.revision == revision
        assert attribution === fixture.goal.binding
        assert_goal_identity(fixture, durable_goal)
        observed = await_normal_exit(writer, observed)
        refute Process.alive?(writer)
        workflow_id = record.id

        assert_receive {:journal_reader_ready, reader, reader_operation, ^workflow_id, ^revision},
                       10_000

        assert reader != writer
        send(reader, {:read_after_normal_writer, workflow_id, revision})

        assert_receive {:journal_reader_result, ^reader, ^reader_operation, {:ok, reopened}},
                       15_000

        observed = await_normal_exit(reader, observed)
        refute Process.alive?(reader)
        assert reopened.record === record
        assert Process.alive?(fixture.parent)
        assert Process.alive?(fixture.session)
        assert Process.alive?(fixture.goal.pid)

        occurrence = %{
          writer: writer,
          operation: operation,
          acknowledged: acknowledged,
          record: record,
          effect: effect,
          reader: reader,
          reader_operation: reader_operation,
          reopened: reopened
        }

        {occurrence, observed}
      end)

    [read, written] = occurrences
    workflow_id = read.record.id
    assert read.acknowledged.revision == 1
    assert read.acknowledged.snapshot === %{"kind" => "workflow", "version" => 1, "effects" => []}
    assert CoreJournal.new() === read.acknowledged.snapshot
    assert written.acknowledged === read.record
    assert written.record.id == workflow_id
    assert read.record.agent_id == fixture.agent.id
    assert written.record.agent_id == fixture.agent.id
    assert Synapsis.AgentConfigs.get(fixture.agent.id) === fixture.agent
    assert fixture.profiles_context.agent.id == fixture.agent.id
    agent_id = fixture.agent.id
    assert {:ok, ^agent_id} = Ecto.UUID.cast(agent_id)

    assert {:ok, result} = Headless.await(fixture.parent, timeout: 20_000)
    assert_receive {:agent_runtime, ^run_id, %{type: :run_completed}}, 5_000
    assert result.status == :completed
    assert result.nested_invocations == 4

    assert result.value === [
             %{
               "workflow_id" => workflow_id,
               "revision" => 3,
               "consumer_value" => read.effect.consumer_value
             },
             %{"revision" => 3, "values" => [read.effect.consumer_value]},
             %{
               "workflow_id" => workflow_id,
               "revision" => 5,
               "consumer_value" => written.effect.consumer_value
             },
             %{
               "revision" => 5,
               "values" => [read.effect.consumer_value, written.effect.consumer_value]
             }
           ]

    assert {:ok, final_record} = Continuations.load(fixture.identity.session_id, workflow_id)
    assert final_record === written.record
    assert {:ok, parent_aggregate} = Store.load(fixture.store, run_id)
    assert Map.get(parent_aggregate.run, :provider_attempts, %{}) == %{}
    assert {:ok, root_goal} = Goal.snapshot(fixture.goal.pid)
    assert {:ok, ^root_goal} = GoalDataStore.load(fixture.identity.session_id)
    assert_goal_identity(fixture, root_goal)
    barrier = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^barrier}, 5_000
    events = Enum.reverse(observed) ++ drain_observation([])

    expected_read = %{
      content: [%{type: "text", text: "workflow journal read\n"}],
      details: %{kind: "text", content: "workflow journal read\n"},
      is_error: false
    }

    expected_write = %{
      content: [%{type: "text", text: "Successfully wrote 9 bytes to output.txt"}],
      details: %{
        diff: "+1 one\n+2 keep",
        firstChangedLine: 1,
        patch: "--- output.txt\n+++ output.txt\n@@ -0,0 +1,2 @@\n+one\n+keep\n",
        changed: true,
        created: true
      },
      is_error: false
    }

    requests = %{
      "read" => expected_request(workflow_id, "read"),
      "write" => expected_request(workflow_id, "write")
    }

    fixture = Map.put(fixture, :requests, requests)
    assert_initial_create(fixture, read, events)
    assert_effect(fixture, {read.operation, read.effect}, expected_read, events)
    assert_effect(fixture, {written.operation, written.effect}, expected_write, events)
    assert read.effect.locator.run_id != written.effect.locator.run_id
    assert read.operation.invocation_id != written.operation.invocation_id
    assert read.effect.retirement.resource_handle != written.effect.retirement.resource_handle

    for {occurrence, pending_revision} <- [{read, 2}, {written, 4}] do
      assert_journal_occurrence(fixture, occurrence, pending_revision, events)
    end

    [first_entry] = read.record.snapshot["effects"]
    assert [^first_entry, _second_entry] = written.record.snapshot["effects"]
    assert {:ok, entries} = CoreJournal.inspect_snapshot(written.record.snapshot)
    assert entries === written.record.snapshot["effects"]
    assert read.reopened.entries === [%{state: :settled, entry: first_entry, effect: read.effect}]

    assert written.reopened.entries ===
             Enum.zip_with(
               written.record.snapshot["effects"],
               [read.effect, written.effect],
               fn entry, effect ->
                 %{state: :settled, entry: entry, effect: effect}
               end
             )

    assert_reader(fixture, read, [read], events)
    assert_reader(fixture, written, occurrences, events)
    assert_calls_count(events, Journal, :create, 1)
    assert_calls_count(events, Journal, :run, 2)
    assert_calls_count(events, Continuations, :create, 1)
    assert_calls_count(events, Continuations, :commit, 4)
    assert_calls_count(events, Effect, :run, 2)
    assert_calls_count(events, Headless, :start_link, 2)
    assert_calls_count(events, Session, :start_link, 2)
    assert_calls_count(events, Filesystem, :execute, 2)
    assert_calls_count(events, Local, :prepare_target, 2)
    assert_distinct_preparations(events, 2)

    receipt_facts =
      for {:trace, _, :call, {RuntimeStore, :put_fact, [_, :workflow_effect_receipt, _, fact]}} <-
            events,
          do: fact

    assert length(receipt_facts) == 2
    assert File.read!(Path.join(root, "input.txt")) == "workflow journal read\n"
    assert File.read!(Path.join(root, "output.txt")) == "one\nkeep\n"

    {root_start_index, ^root_worker_supervisor, [_options]} =
      one_call_from(events, root_worker_supervisor, CodeMode.Worker, :start_link, fn [_] ->
        true
      end)

    assert {:ok, root_worker} =
             return_after(
               events,
               root_start_index,
               root_worker_supervisor,
               {CodeMode.Worker, :start_link, 1}
             )

    {identity_index, parent, [^root_worker]} =
      one_call_from(events, fixture.parent, CodeMode.Worker, :os_identity, fn [worker] ->
        worker == root_worker
      end)

    assert parent == fixture.parent

    assert {:ok, root_os_identity} =
             return_after(events, identity_index, parent, {CodeMode.Worker, :os_identity, 1})

    root_os_pid = Map.fetch!(root_os_identity, :pid)

    assert return_index(
             events,
             root_start_index,
             root_worker_supervisor,
             {CodeMode.Worker, :start_link, 1}
           ) < identity_index

    # Ordinary teardown closes only this fixture's owned native root.
    assert normal_exit_index(events, root_worker) >= 0
    refute Process.alive?(root_worker)
    parent_ref = Process.monitor(fixture.parent)
    assert :ok = GenServer.stop(fixture.parent, :normal, 5_000)
    assert_receive {:DOWN, ^parent_ref, :process, _, :normal}, 5_000
    assert {:ok, %{status: :confirmed}} = Session.close(fixture.session)
    refute File.exists?("/proc/#{root_os_pid}")
    session_ref = Process.monitor(fixture.session)
    registry_ref = Process.monitor(fixture.binding.resource_registry)
    assert :ok = GenServer.stop(fixture.session, :normal, 5_000)
    assert_receive {:DOWN, ^session_ref, :process, _, :normal}, 5_000
    assert_receive {:DOWN, ^registry_ref, :process, _, :normal}, 5_000

    # Previously captured full effects and aggregates remain exact after root closure.
    for occurrence <- occurrences do
      reference = List.last(occurrence.record.snapshot["effects"])["receipt"]

      assert {:ok, fact} =
               RuntimeStore.get_fact(
                 fixture.identity.session_id,
                 :workflow_effect_receipt,
                 reference["fact_id"]
               )

      assert fact.effect === occurrence.effect
      assert {:ok, aggregate} = RuntimeStore.load(reference["namespace"], reference["run_id"])
      assert aggregate.revision == reference["final_revision"]
    end

    assert File.read!(Path.join(root, "output.txt")) == "one\nkeep\n"
  end

  defp open_fixture(root) do
    assert File.regular?(@node)
    assert :ok = SessionStore.ensure_started()
    session_id = Ecto.UUID.generate()
    run_id = Ecto.UUID.generate()
    caller = "synapsis:" <> session_id
    names = ["exec", "wait", "synapsis::read", "synapsis::write"]
    all_names = names ++ [@caller_tool]
    assert {:ok, store} = Store.new(1)

    assert {:ok, agent} =
             Synapsis.AgentConfigs.create(%{
               name: "workflow-journal-#{session_id}",
               enabled: true,
               tools: names,
               tool_contract_version: 1,
               permission_mode: "yolo"
             })

    permission = %Synapsis.SessionPermission{
      session_id: session_id,
      mode: :autonomous,
      allow_read: :allow,
      allow_write: :allow,
      allow_execute: :allow,
      allow_destructive: :allow,
      tool_contract_version: 1
    }

    assert :ok = SessionStore.put_value(session_id, "permission", permission)

    on_exit(fn ->
      SessionStore.delete_session(session_id)
      Synapsis.AgentConfigs.delete(agent)
      cleanup_journal(session_id, store.namespace)
      Concord.Turso.delete("coord/goals/threads/" <> session_id, timeout: 5_000)
    end)

    identity = %{
      caller: caller,
      session_id: session_id,
      run_id: run_id,
      incarnation: 1,
      catalog_revision: 1
    }

    ceiling = %{
      caller: caller,
      run_id: run_id,
      grants: all_names,
      tool_revision: 1,
      tool_revisions: Map.new(all_names, &{&1, 1})
    }

    session = start_supervised!({Session, owner_pid: self(), cleanup_timeout: 5_000})
    assert {:ok, binding} = Session.bind(session, ceiling, incarnation: 1)
    goal = start_goal(session_id, ceiling)
    assert {:ok, native} = HostCodeMode.bundles(%{session_binding: binding}, ceiling, names)

    adapter = start_supervised!({AdapterHost, self()})

    fetch = fn invocation, catalog, digest ->
      GenServer.call(adapter, {:filesystem_target_fetch, invocation, catalog, digest}, 5_000)
    end

    profiles_context = %{
      session: %{id: session_id, config: %{"subagents" => false}},
      agent: %{id: agent.id, name: agent.name, tools: names, tool_contract_version: 1},
      project_path: root,
      tool_filesystem: %{
        path_environment: %{
          cwd: root,
          os_home: Path.join(root, "home"),
          platform: :linux,
          workspace_root: root
        },
        prepared_target_resolver: fetch,
        execution_options: [
          node_executable: @node,
          model_budget: nil,
          model_has_vision: true,
          auto_resize_images: true
        ]
      }
    }

    assert {:ok, %{bundle: original, snapshot: snapshot}} =
             Profiles.build(profiles_context, identity, native, ceiling)

    assert snapshot.permission === permission

    for field <- [:session_id, :caller, :run_id, :incarnation, :catalog_revision],
        do: assert(snapshot.scope[field] === identity[field])

    assert Enum.sort(Map.keys(snapshot.issued_descriptors)) == Enum.sort(names)
    assert original.registry.tools["exec"].backend == Codex.Backend

    reader_supervisor = start_supervised!(Task.Supervisor)

    registration = SessionAdapter.workflow_effect_registration(adapter, run_id, 1)

    descriptor = %{
      tool_name: @caller_tool,
      tool_revision: 1,
      backend: StrictCallerBackend,
      backend_context: %{
        observer: self(),
        adapter: adapter,
        workflow_effect_registration: registration,
        reader_supervisor: reader_supervisor,
        session_binding: binding,
        profiles_context: profiles_context,
        ceiling: ceiling,
        store: store,
        session_id: session_id,
        caller: caller
      },
      schema: %{
        "type" => "object",
        "properties" => %{
          "effect" => %{"type" => "string", "enum" => ["read", "write", "reopen"]},
          "workflow_id" => %{"type" => "string"},
          "revision" => %{"type" => "integer"}
        },
        "required" => ["effect"],
        "additionalProperties" => false
      },
      safety: %{read_only: false, retry_safe: false, parallel_safe: false}
    }

    assert {:ok, catalog} = Catalog.compose([original], [descriptor], ceiling, all_names)

    for name <- names,
        do: assert(catalog.registry.tools[name] === snapshot.issued_descriptors[name])

    snapshot = %{snapshot | issued_descriptors: catalog.registry.tools}
    pinned = Map.put(Map.take(catalog, [:registry, :tools, :authority]), :revision, 1)
    assert {:ok, snapshot} = Profiles.project_catalog(identity, snapshot, pinned)
    assert :ok = GenServer.call(adapter, {:install_root, {run_id, 1}, snapshot}, 5_000)

    options = [
      run_id: run_id,
      incarnation: 1,
      goal: goal.pid,
      goal_binding: goal.binding,
      thread_id: session_id,
      session_binding: binding,
      registry: catalog.registry,
      tools: catalog.tools,
      authority: catalog.authority,
      store: Store,
      context: store,
      subscriber: self(),
      work: 8,
      run_timeout: 60_000,
      effect_timeout: 45_000,
      commit_timeout: 5_000,
      cleanup_timeout: 5_000
    ]

    assert {:ok, parent} = Headless.start_link(options)
    on_exit(fn -> if Process.alive?(parent), do: GenServer.stop(parent, :normal, 5_000) end)

    %{
      parent: parent,
      adapter: adapter,
      registration: registration,
      goal: goal,
      session: session,
      binding: binding,
      identity: identity,
      names: names,
      agent: agent,
      store: store,
      snapshot: snapshot,
      profiles_context: profiles_context,
      ceiling: ceiling
    }
  end

  defp assert_effect(fixture, {parent_operation, effect}, expected, events) do
    request = Map.fetch!(fixture.requests, parent_operation.arguments["effect"])
    names = ["exec", "wait", request.target.tool_name]
    fixture = fixture |> Map.put(:request, request) |> Map.put(:names, names)

    assert Map.keys(effect) |> Enum.sort() ==
             Enum.sort([:request, :locator, :receipt, :consumer_value, :retirement])

    assert effect.request === fixture.request
    assert effect.consumer_value === json_value(Map.delete(expected, :is_error))
    locator = effect.locator
    assert {:ok, _uuid} = Ecto.UUID.cast(locator.run_id)
    assert locator.run_id != fixture.identity.run_id

    assert locator === %{
             version: 1,
             session_id: fixture.identity.session_id,
             namespace: fixture.store.namespace,
             run_id: locator.run_id,
             incarnation: 1,
             kind: :workflow_effect,
             name: nil,
             agent_id: nil,
             parent_run_id: fixture.identity.run_id,
             parent_incarnation: 1,
             parent_invocation_id: parent_operation.invocation_id,
             effect_request: fixture.request
           }

    assert parent_operation.effective_authority ===
             parent_operation.backend_context.catalog_snapshot.authority

    assert parent_operation.backend_context.goal === fixture.goal.pid
    assert parent_operation.backend_context.goal_binding === fixture.goal.binding
    assert parent_operation.backend_context.ceiling === fixture.ceiling
    assert {:ok, aggregate} = Store.load(fixture.store, locator.run_id)
    record = aggregate.run
    receipt = effect.receipt
    outer = receipt.outer_intent.operation
    target = receipt.target_intent.operation
    assert record.state == :completed
    assert Map.get(record, :active_tools, %{}) == %{}
    assert record[:active_provider] == nil
    assert record[:active_wait] == nil
    assert record.context.execution_mode == :headless
    assert record.context.conversation.headless_result.value === effect.consumer_value
    assert record.context.conversation.headless_result.nested_invocations == 1
    assert record.context.conversation.headless_result.outer_reservations == 1
    assert Map.get(record, :provider_attempts, %{}) == %{}
    assert map_size(record.execution_intents) == 2
    assert map_size(record.tool_results) == 2

    assert Enum.sort(Enum.map(record.context.headless_catalog["tools"], & &1["tool_name"])) ==
             Enum.sort(fixture.names)

    assert receipt === %{
             version: 1,
             run_id: locator.run_id,
             incarnation: 1,
             turn_id: outer.turn_id,
             catalog_revision: 1,
             catalog_digest: record.context.headless_catalog["descriptor_digest"],
             outer_intent: record.execution_intents["tool:#{outer.invocation_id}"],
             target_intent: record.execution_intents["tool:#{target.invocation_id}"],
             target_result: expected,
             target_presentation: nil,
             final_revision: aggregate.revision
           }

    assert aggregate.revision == record.expected_revision
    assert receipt.outer_intent.status == :consumed
    assert receipt.target_intent.status == :consumed
    assert receipt.outer_intent.reservation.reservation_id == "tool:#{outer.invocation_id}"
    assert receipt.target_intent.reservation.reservation_id == "tool:#{target.invocation_id}"
    assert outer.arguments === @source
    assert outer.tool_name == "exec"
    assert outer.enclosing_invocation_id == outer.invocation_id
    assert target.arguments === fixture.request.target.arguments
    assert target.tool_name == fixture.request.target.tool_name
    assert target.enclosing_invocation_id == outer.invocation_id

    for field <- [
          :run_id,
          :incarnation,
          :turn_id,
          :step_id,
          :attempt_id,
          :catalog_revision,
          :caller
        ],
        do: assert(target[field] === outer[field])

    assert outer.run_id == locator.run_id
    assert outer.caller == fixture.identity.caller
    assert outer.tool_revision == 1
    assert target.tool_revision == fixture.request.target.tool_revision
    assert record.tool_results[target.invocation_id] === expected
    assert Map.get(record.tool_presentations, target.invocation_id) == nil

    assert record.tool_results[outer.invocation_id] === %{
             status: :completed,
             value: effect.consumer_value,
             output: [],
             output_truncated: false,
             is_error: false
           }

    assert_native_observation(fixture, parent_operation, effect, aggregate, events)
  end

  defp assert_native_observation(fixture, parent_operation, effect, aggregate, events) do
    run_id = effect.locator.run_id

    {retain_index, retain_pid, _} =
      one_call(events, RunInventory, :retain, fn [locator] -> locator === effect.locator end)

    assert return_after(events, retain_index, retain_pid, {RunInventory, :retain, 1}) === :ok

    {start_index, start_pid, [options]} =
      one_call(events, Headless, :start_link, fn [opts] -> opts[:run_id] == run_id end)

    assert retain_index < start_index
    assert options[:store] == Store
    assert options[:context] == fixture.store
    assert options[:hooks] == Policy
    refute Keyword.has_key?(options, :provider)
    refute Keyword.has_key?(options, :provider_context)
    assert {:ok, child} = return_after(events, start_index, start_pid, {Headless, :start_link, 1})
    child_binding = options[:session_binding]
    assert child_binding.session != fixture.session
    assert child_binding.resource_registry != fixture.binding.resource_registry

    {session_index, _, _} =
      one_call(events, Session, :start_link, fn [opts] -> opts[:owner_pid] == start_pid end)

    assert retain_index < session_index

    {execute_index, execute_pid, [^child, source, execute_options]} =
      one_call(events, Headless, :execute, fn [pid, _, _] -> pid == child end)

    assert source === @source

    assert execute_options === [
             input: %{
               "tool_name" => fixture.request.target.tool_name,
               "arguments" => fixture.request.target.arguments
             }
           ]

    assert {:ok, acknowledgement} =
             return_after(events, execute_index, execute_pid, {Headless, :execute, 3})

    assert acknowledgement.run_id == run_id
    assert acknowledgement.incarnation == 1
    assert acknowledgement.turn_id == effect.receipt.turn_id

    {build_index, build_pid, [host_context, identity, _, _]} =
      one_call(events, Profiles, :build, fn [_, identity, _, _] -> identity.run_id == run_id end)

    expected_profiles =
      put_in(fixture.profiles_context, [:agent, :tools], fixture.names)

    assert Map.take(host_context, [:session, :agent, :project_path]) ===
             Map.take(expected_profiles, [:session, :agent, :project_path])

    assert {:ok, %{bundle: bundle, snapshot: snapshot}} =
             return_after(events, build_index, build_pid, {Profiles, :build, 4})

    assert snapshot.permission === fixture.snapshot.permission
    assert snapshot.evidence === fixture.snapshot.evidence
    assert Enum.sort(Map.keys(bundle.registry.tools)) == Enum.sort(fixture.names)
    assert options[:registry] === bundle.registry
    assert options[:tools] === bundle.tools
    assert options[:authority] === bundle.authority
    assert_native_goal(fixture, parent_operation, effect, child, options, events)

    assert_preparation(
      fixture,
      parent_operation,
      effect,
      bundle,
      snapshot,
      host_context,
      options,
      events
    )

    assert identity.caller == fixture.identity.caller

    assert [{{:tool_context, projected_identity, pinned}, _, {:ok, projected_snapshot}, _}] =
             adapter_calls(events, :tool_context, fn {_, op, _} ->
               op.run_id == run_id and op.tool_name == fixture.request.target.tool_name
             end)

    assert pinned.registry === bundle.registry
    adapter = fixture.adapter

    {projection_index, ^adapter, [^projected_identity, projection_input, ^pinned]} =
      one_call(events, Profiles, :project_catalog, fn [op, _, _] ->
        op.run_id == run_id and op.tool_name == fixture.request.target.tool_name
      end)

    # Build-time and projected classifiers capture different catalog contexts.
    # Compare the exact production call/return, never a second projection's closures.
    assert projection_input === snapshot

    assert return_after(events, projection_index, adapter, {Profiles, :project_catalog, 3}) ===
             {:ok, projected_snapshot}

    for field <- [
          :run_id,
          :incarnation,
          :catalog_revision,
          :invocation_id,
          :tool_name,
          :tool_revision
        ],
        do: assert(projected_identity[field] === effect.receipt.target_intent.operation[field])

    assert Map.drop(projected_snapshot, [:scope, :selected, :known_bindings]) ===
             Map.drop(snapshot, [:scope, :selected, :known_bindings])

    assert projected_snapshot.scope ===
             Map.put(snapshot.scope, :catalog_revision, pinned.revision)

    assert Enum.sort(Map.keys(projected_snapshot.selected)) ===
             Enum.sort(Map.keys(pinned.registry.tools))

    for {name, descriptor} <- pinned.registry.tools do
      assert projected_snapshot.issued_descriptors[name] === descriptor
      assert projected_snapshot.selected[name].tool_revision === descriptor.tool_revision
      assert is_function(projected_snapshot.selected[name].classify, 1)
    end

    assert projected_snapshot.known_bindings ===
             Map.merge(snapshot.known_bindings, projected_snapshot.selected)

    {registration_index, registration_pid, [registry, owner, :workflow_effect, value, _]} =
      one_call(events, ResourceRegistry, :register, fn [registry, _, kind, value, _] ->
        registry == fixture.binding.resource_registry and kind == :workflow_effect and
          value.locator == effect.locator
      end)

    assert value === %{session: child_binding.session, headless: child, locator: effect.locator}
    assert owner == fixture.binding.owner_id
    assert registration_index < execute_index

    assert {:ok, handle} =
             return_after(
               events,
               registration_index,
               registration_pid,
               {ResourceRegistry, :register, 5}
             )

    assert effect.retirement === %{
             resource_handle: handle,
             release: :confirmed,
             headless: :normal,
             session: :normal,
             registry: :normal
           }

    {release_index, release_pid, [^registry, ^handle, ^owner]} =
      one_call(events, ResourceRegistry, :release, fn [r, h, o] ->
        r == registry and h == handle and o == owner
      end)

    assert return_after(events, release_index, release_pid, {ResourceRegistry, :release, 3}) ===
             {:ok, :ok}

    assert {:ok, %{status: :confirmed}} = ResourceRegistry.cleanup_status(registry, handle, owner)

    for pid <- [child, child_binding.session, child_binding.resource_registry] do
      assert Enum.any?(events, &match?({:trace, ^pid, :exit, :normal}, &1))
      refute Process.alive?(pid)
    end

    {worker_registration_index, worker_registration_pid, [_, _, :continuation, worker, _]} =
      one_call(events, ResourceRegistry, :register, fn [r, _, kind, _, _] ->
        r == child_binding.resource_registry and kind == :continuation
      end)

    identity_calls =
      for {{:trace, caller, :call, {CodeMode.Worker, :os_identity, [^worker]}}, index} <-
            Enum.with_index(events),
          do: {index, caller}

    assert [{worker_index, ^worker_registration_pid}, {validation_index, ^child}] = identity_calls
    assert worker_index < worker_registration_index
    assert worker_registration_index < validation_index

    assert {:ok, %{pid: os_pid} = os_identity} =
             return_after(
               events,
               worker_index,
               worker_registration_pid,
               {CodeMode.Worker, :os_identity, 1}
             )

    assert return_after(events, validation_index, child, {CodeMode.Worker, :os_identity, 1}) ===
             {:ok, os_identity}

    assert Enum.any?(events, &match?({:trace, ^worker, :exit, :normal}, &1))
    refute Process.alive?(worker)
    refute File.exists?("/proc/#{os_pid}")

    {finish_index, finish_pid, _} =
      one_call(events, Store, :store, fn [_, record, meta] ->
        record.run_id == run_id and elem(meta.command, 0) == :finish
      end)

    assert {:ok, %{revision: revision}} =
             return_after(events, finish_index, finish_pid, {Store, :store, 3})

    assert revision == aggregate.revision

    assert Enum.any?(events, fn
             {:trace, pid, :return_from, {Headless, :status, 1},
              %{phase: :terminal, resource_cleanup: :confirmed, run: record}} ->
               pid == execute_pid and record === aggregate.run

             _ ->
               false
           end)

    assert parent_operation.invocation_id == effect.locator.parent_invocation_id
  end

  defp start_goal(session_id, authority) do
    goal =
      start_supervised!(
        {Goal,
         thread_id: session_id,
         owner_pid: self(),
         store: GoalStore,
         store_context: :local,
         host: GoalHost,
         host_context: self()}
      )

    instruction = %{text: "Read and write the requested workspace files"}

    assert {:ok, %{goal: %{status: :active, tokens_used: 0}}} =
             Goal.set(goal, %{objective: instruction.text}, instruction)

    assert_receive {:goal_instruction, ^session_id, ^instruction}, 5_000
    assert {:ok, initial} = Goal.snapshot(goal)
    assert {:ok, ^initial} = GoalDataStore.load(session_id)
    assert initial.goal.token_budget == nil

    assert {:ok, binding} =
             Goal.bind(goal, %{
               thread_id: session_id,
               run_id: authority.run_id,
               incarnation: 1,
               authority: authority
             })

    assert binding.mode == :execution
    assert binding.usage_authoritative == false
    %{pid: goal, binding: binding, initial: initial}
  end

  defp assert_goal_identity(fixture, root) do
    assert root.thread_id == fixture.identity.session_id
    assert root.goal.goal_id == fixture.goal.initial.goal.goal_id
    assert root.goal.objective == "Read and write the requested workspace files"
    assert root.goal.status == :active
    assert root.goal.token_budget == nil
    assert root.goal.tokens_used == 0
    assert root.usage === fixture.goal.initial.usage
    assert root.usage_snapshots === fixture.goal.initial.usage_snapshots
    assert root.baselines === fixture.goal.initial.baselines
    assert root.usage_baselines === fixture.goal.initial.usage_baselines
    assert root.accounting_uncertain == false
    assert root.continuation_deferral == nil
    assert Process.alive?(fixture.goal.pid)
  end

  defp assert_native_goal(fixture, parent_operation, effect, child, options, events) do
    goal = fixture.goal.pid
    run_id = effect.locator.run_id

    {delegate_index, delegate_pid, [^goal, parent_binding, attributes]} =
      one_call(events, Goal, :delegate, fn [pid, _, attrs] ->
        pid == goal and attrs.run_id == run_id
      end)

    assert parent_binding === fixture.goal.binding
    assert parent_binding === parent_operation.backend_context.goal_binding

    expected_authority =
      parent_operation.effective_authority
      |> Map.put(:run_id, run_id)
      |> Map.put(:grants, fixture.names)
      |> Map.update!(:tool_revisions, &Map.take(&1, fixture.names))

    assert options[:authority] === expected_authority

    assert attributes === %{
             thread_id: run_id,
             run_id: run_id,
             incarnation: effect.locator.incarnation,
             authority: options[:authority]
           }

    assert {:ok, delegated} =
             return_after(events, delegate_index, delegate_pid, {Goal, :delegate, 3})

    assert delegated.thread_id == run_id
    assert delegated.run_id == run_id
    assert delegated.incarnation == effect.locator.incarnation
    assert delegated.root_thread_id == fixture.identity.session_id
    assert delegated.root_goal_id == fixture.goal.initial.goal.goal_id
    assert delegated.expected_goal_id == fixture.goal.initial.goal.goal_id
    assert delegated.mode === fixture.goal.binding.mode
    assert delegated.usage_authoritative === fixture.goal.binding.usage_authoritative
    assert delegated.authority === attributes.authority
    assert delegated.capability != parent_binding.capability
    assert options[:goal] === goal
    assert options[:goal_binding] === delegated
    assert options[:thread_id] === delegated.thread_id

    {start_index, _, _} =
      one_call(events, Headless, :start_link, fn [opts] -> opts[:run_id] == run_id end)

    assert delegate_index < start_index

    {unbind_index, unbind_pid, [^goal, ^delegated]} =
      one_call(events, Goal, :unbind, fn [pid, binding] ->
        pid == goal and binding === delegated
      end)

    assert return_after(events, unbind_index, unbind_pid, {Goal, :unbind, 2}) === {:ok, :unbound}
    unbound_index = return_index(events, unbind_index, unbind_pid, {Goal, :unbind, 2})

    # Read-only observation of pinned native Conversation emission: the real
    # completion notification follows acknowledgement, before owned retirement.
    {completed_index, ^child, [state, %{type: :run_completed}]} =
      one_call(events, Conversation, :emit, fn [state, event] ->
        state.run.run_id == run_id and event.type == :run_completed
      end)

    assert state.goal_binding == nil
    assert state.goal_delivery == nil
    assert state.run.state == :completed
    assert state.resource_cleanup == :confirmed
    assert unbound_index < completed_index

    {effect_index, effect_pid, [request, supplied]} =
      one_call(events, Effect, :run, fn [_, context] ->
        context.operation.invocation_id == parent_operation.invocation_id
      end)

    assert request === fixture.request
    refute Map.has_key?(supplied, :goal)
    refute Map.has_key?(supplied, :goal_binding)
    assert return_after(events, effect_index, effect_pid, {Effect, :run, 2}) === {:ok, effect}
    returned_index = return_index(events, effect_index, effect_pid, {Effect, :run, 2})

    {release_index, _, _} =
      one_call(events, ResourceRegistry, :release, fn [registry, handle, owner] ->
        registry == fixture.binding.resource_registry and
          handle == effect.retirement.resource_handle and owner == fixture.binding.owner_id
      end)

    assert completed_index < release_index
    assert release_index < returned_index

    for pid <- [
          child,
          options[:session_binding].session,
          options[:session_binding].resource_registry
        ] do
      [{_, retired_index}] =
        events
        |> Enum.with_index()
        |> Enum.filter(fn {event, _} -> event === {:trace, pid, :exit, :normal} end)

      assert completed_index < retired_index
      assert retired_index < returned_index
    end

    assert {:ok, aggregate} = Store.load(fixture.store, run_id)
    assert aggregate.run.run_id == delegated.run_id
    assert aggregate.run.incarnation == delegated.incarnation
    assert aggregate.run.context.conversation.goal_outbox == []
    assert Map.get(aggregate.run.context.conversation, :goal_usage) == nil
    assert Map.get(aggregate.run, :provider_attempts, %{}) == %{}
  end

  defp return_index(events, index, pid, mfa) do
    assert {_, returned_index} =
             events
             |> Enum.with_index()
             |> Enum.drop(index + 1)
             |> Enum.find(fn
               {{:trace, ^pid, :return_from, ^mfa, _}, _} -> true
               _ -> false
             end)

    returned_index
  end

  defp assert_initial_create(fixture, occurrence, events) do
    record = occurrence.acknowledged
    session_id = fixture.identity.session_id
    agent_id = fixture.agent.id

    {create_index, writer, [supplied]} =
      one_call(events, Journal, :create, fn [context] ->
        context.operation.invocation_id == occurrence.operation.invocation_id
      end)

    assert writer == occurrence.writer
    assert supplied.profiles_context === fixture.profiles_context
    assert supplied.profiles_snapshot === fixture.snapshot
    assert return_after(events, create_index, writer, {Journal, :create, 1}) === {:ok, record}

    {store_index, ^writer, [^session_id, ^agent_id, snapshot, options]} =
      one_call(events, Continuations, :create, fn [_, _, _, _] -> true end)

    assert snapshot === %{"kind" => "workflow", "version" => 1, "effects" => []}
    assert is_integer(options[:deadline])

    assert return_after(events, store_index, writer, {Continuations, :create, 4}) ===
             {:ok, record}

    assert record.schema_version == 1
    assert record.session_id == session_id
    assert record.agent_id == agent_id
    assert record.revision == 1
    assert {:ok, workflow_id} = Ecto.UUID.cast(record.id)
    assert workflow_id == record.id

    {cas_index, ^writer, [key, ^record, cas_options]} =
      one_call(events, Concord.Turso, :compare_and_swap, fn [_, candidate, _] ->
        candidate == record
      end)

    assert key == "coord/workflow_continuations/" <> session_id <> "/" <> record.id
    assert cas_options[:mod_revision] == 0

    assert {:ok, %{succeeded: true}} =
             return_after(events, cas_index, writer, {Concord.Turso, :compare_and_swap, 3})

    assert create_index < store_index
    assert store_index < cas_index

    assert return_index(events, cas_index, writer, {Concord.Turso, :compare_and_swap, 3}) <
             return_index(events, store_index, writer, {Continuations, :create, 4})
  end

  defp assert_journal_occurrence(fixture, occurrence, pending_revision, events) do
    %{operation: operation, acknowledged: acknowledged, record: record, effect: effect} =
      occurrence

    workflow_id = record.id
    session_id = fixture.identity.session_id
    request = Map.fetch!(fixture.requests, operation.arguments["effect"])
    assert effect.request === request
    request_json = expected_json_request(request)
    assert CoreJournal.encode_request(request) === {:ok, request_json}
    assert CoreJournal.decode_request(request_json) === {:ok, request}

    origin = %{
      "namespace" => fixture.store.namespace,
      "store_incarnation" => fixture.store.incarnation,
      "parent_run_id" => operation.run_id,
      "parent_incarnation" => operation.incarnation,
      "parent_invocation_id" => operation.invocation_id,
      "caller" => operation.caller,
      "resource_owner_id" => fixture.binding.owner_id,
      "resource_incarnation" => fixture.binding.incarnation
    }

    pending_entry = %{
      "state" => "pending",
      "pending_revision" => pending_revision,
      "request" => request_json,
      "origin" => origin
    }

    pending_snapshot = %{
      "kind" => "workflow",
      "version" => 1,
      "effects" => acknowledged.snapshot["effects"] ++ [pending_entry]
    }

    {pending_index, writer,
     [^session_id, ^workflow_id, previous_revision, ^pending_snapshot, options]} =
      one_call(events, Continuations, :commit, fn [_, id, _, snapshot, _] ->
        id == workflow_id and List.last(snapshot["effects"]) == pending_entry
      end)

    assert writer == occurrence.writer
    assert previous_revision == acknowledged.revision
    assert previous_revision + 1 == pending_revision
    assert is_integer(options[:deadline])

    assert {:ok, pending_record} =
             return_after(events, pending_index, writer, {Continuations, :commit, 5})

    assert pending_record.revision == pending_revision
    assert pending_record.snapshot === pending_snapshot

    assert Map.drop(pending_record, [:revision, :updated_at, :snapshot]) ===
             Map.drop(acknowledged, [:revision, :updated_at, :snapshot])

    pending_ack_index = return_index(events, pending_index, writer, {Continuations, :commit, 5})

    {cas_index, ^writer, [_, ^pending_record, _]} =
      one_call(events, Concord.Turso, :compare_and_swap, fn [_, candidate, _] ->
        candidate == pending_record
      end)

    assert {:ok, %{succeeded: true}} =
             return_after(events, cas_index, writer, {Concord.Turso, :compare_and_swap, 3})

    assert return_index(events, cas_index, writer, {Concord.Turso, :compare_and_swap, 3}) <
             pending_ack_index

    {effect_index, ^writer, [^request, supplied]} =
      one_call(events, Effect, :run, fn [_, context] ->
        context.operation.invocation_id == operation.invocation_id
      end)

    assert supplied.operation === operation
    assert supplied.profiles_context === fixture.profiles_context
    assert supplied.profiles_snapshot === fixture.snapshot
    assert supplied.session_binding === fixture.binding
    assert supplied.ceiling === fixture.ceiling
    assert supplied.store === fixture.store
    assert return_after(events, effect_index, writer, {Effect, :run, 2}) === {:ok, effect}
    effect_return_index = return_index(events, effect_index, writer, {Effect, :run, 2})
    assert pending_ack_index < effect_index

    for {module, function, predicate} <- [
          {RunInventory, :retain, fn [locator] -> locator === effect.locator end},
          {Headless, :start_link, fn [opts] -> opts[:run_id] == effect.locator.run_id end},
          {Filesystem, :execute, fn [op] -> op.run_id == effect.locator.run_id end}
        ] do
      {index, _, _} = one_call(events, module, function, predicate)
      assert pending_ack_index < index
    end

    {session_index, _, _} =
      one_call(events, Session, :start_link, fn [opts] ->
        opts[:owner_pid] == writer
      end)

    assert pending_ack_index < session_index

    {finish_index, finish_pid, _} =
      one_call(events, Store, :store, fn [_, run, meta] ->
        run.run_id == effect.locator.run_id and elem(meta.command, 0) == :finish
      end)

    assert {:ok, %{revision: final_revision}} =
             return_after(events, finish_index, finish_pid, {Store, :store, 3})

    assert final_revision == effect.receipt.final_revision

    assert return_index(events, finish_index, finish_pid, {Store, :store, 3}) <
             effect_return_index

    {start_index, start_pid, [start_options]} =
      one_call(events, Headless, :start_link, fn [opts] ->
        opts[:run_id] == effect.locator.run_id
      end)

    assert {:ok, child} = return_after(events, start_index, start_pid, {Headless, :start_link, 1})
    child_binding = start_options[:session_binding]

    {_, _, [_, _, :continuation, worker, _]} =
      one_call(events, ResourceRegistry, :register, fn [registry, _, kind, _, _] ->
        registry == child_binding.resource_registry and kind == :continuation
      end)

    for retired <- [child, child_binding.session, child_binding.resource_registry, worker] do
      assert normal_exit_index(events, retired) < effect_return_index
    end

    fact_id = workflow_id <> ":" <> Integer.to_string(pending_revision)

    expected_fact = %{
      version: 1,
      workflow_id: workflow_id,
      agent_id: fixture.agent.id,
      pending_revision: pending_revision,
      effect: effect
    }

    {fact_index, ^writer, [^session_id, :workflow_effect_receipt, ^fact_id, fact]} =
      one_call(events, RuntimeStore, :put_fact, fn [_, kind, id, _] ->
        kind == :workflow_effect_receipt and id == fact_id
      end)

    assert fact === expected_fact
    assert plain_native_term?(fact)
    assert return_after(events, fact_index, writer, {RuntimeStore, :put_fact, 4}) === :ok
    fact_ack_index = return_index(events, fact_index, writer, {RuntimeStore, :put_fact, 4})
    assert effect_return_index < fact_index

    fact_key =
      "coord/runtime/facts/" <>
        segment(session_id) <>
        "/" <>
        segment(:workflow_effect_receipt) <> "/" <> segment(fact_id)

    expected_txn = %{
      compare: [{:exists, fact_key, :==, false}],
      success: [{:put, fact_key, expected_fact, %{}}],
      failure: []
    }

    {txn_index, ^writer, [^expected_txn, _]} =
      one_call(events, Concord.Turso, :txn, fn [spec, _] ->
        spec == expected_txn
      end)

    assert {:ok, %{succeeded: true}} =
             return_after(events, txn_index, writer, {Concord.Turso, :txn, 2})

    assert fact_index < txn_index
    assert return_index(events, txn_index, writer, {Concord.Turso, :txn, 2}) < fact_ack_index

    assert RuntimeStore.get_fact(session_id, :workflow_effect_receipt, fact_id) ===
             {:ok, expected_fact}

    handle = effect.retirement.resource_handle

    assert Map.keys(handle) |> Enum.sort() ==
             Enum.sort([:resource_id, :owner_id, :incarnation, :kind])

    assert is_binary(handle.resource_id) and handle.resource_id != ""
    assert handle.owner_id == fixture.binding.owner_id
    assert handle.incarnation == fixture.binding.incarnation
    assert handle.kind == :workflow_effect

    reference = %{
      "kind" => "workflow_effect_receipt",
      "fact_id" => fact_id,
      "namespace" => effect.locator.namespace,
      "run_id" => effect.locator.run_id,
      "incarnation" => effect.locator.incarnation,
      "final_revision" => effect.receipt.final_revision
    }

    settled_entry =
      Map.merge(pending_entry, %{
        "state" => "settled",
        "settled_revision" => pending_revision + 1,
        "receipt" => reference
      })

    assert record.snapshot === %{
             "kind" => "workflow",
             "version" => 1,
             "effects" => acknowledged.snapshot["effects"] ++ [settled_entry]
           }

    assert record.revision == pending_revision + 1

    assert Map.drop(record, [:revision, :updated_at, :snapshot]) ===
             Map.drop(pending_record, [:revision, :updated_at, :snapshot])

    {settle_index, ^writer, [^session_id, ^workflow_id, ^pending_revision, snapshot, _]} =
      one_call(events, Continuations, :commit, fn [_, id, revision, snapshot, _] ->
        id == workflow_id and revision == pending_revision and snapshot == record.snapshot
      end)

    assert snapshot === record.snapshot
    assert fact_ack_index < settle_index

    assert return_after(events, settle_index, writer, {Continuations, :commit, 5}) ===
             {:ok, record}

    {settled_cas_index, ^writer, [_, ^record, _]} =
      one_call(events, Concord.Turso, :compare_and_swap, fn [_, candidate, _] ->
        candidate == record
      end)

    assert {:ok, %{succeeded: true}} =
             return_after(
               events,
               settled_cas_index,
               writer,
               {Concord.Turso, :compare_and_swap, 3}
             )

    assert return_index(events, settled_cas_index, writer, {Concord.Turso, :compare_and_swap, 3}) <
             return_index(events, settle_index, writer, {Continuations, :commit, 5})

    {journal_index, ^writer, [^acknowledged, ^request, _]} =
      one_call(events, Journal, :run, fn [_, _, context] ->
        context.operation.invocation_id == operation.invocation_id
      end)

    assert return_after(events, journal_index, writer, {Journal, :run, 3}) ===
             {:ok, %{record: record, effect: effect}}

    assert return_index(events, settle_index, writer, {Continuations, :commit, 5}) <
             return_index(events, journal_index, writer, {Journal, :run, 3})

    assert return_index(events, journal_index, writer, {Journal, :run, 3}) <
             normal_exit_index(events, writer)
  end

  defp assert_reader(fixture, occurrence, expected_occurrences, events) do
    reader = occurrence.reader
    reader_events = Enum.filter(events, &(elem(&1, 1) == reader))
    session_id = fixture.identity.session_id
    agent_id = fixture.agent.id
    workflow_id = occurrence.record.id
    revision = occurrence.record.revision

    {reopen_index, ^reader, [^session_id, ^agent_id, ^workflow_id, ^revision, options]} =
      one_call_from(events, reader, Journal, :reopen, fn [_, _, _, expected, _] ->
        expected == revision
      end)

    assert is_integer(options[:deadline])
    assert normal_exit_index(events, occurrence.writer) < reopen_index

    assert return_after(events, reopen_index, reader, {Journal, :reopen, 5}) ===
             {:ok, occurrence.reopened}

    assert return_index(events, reopen_index, reader, {Journal, :reopen, 5}) <
             normal_exit_index(events, reader)

    {load_index, ^reader, [^session_id, ^workflow_id, _]} =
      one_call(reader_events, Continuations, :load, fn [_, _, _] -> true end)

    assert return_after(reader_events, load_index, reader, {Continuations, :load, 3}) ===
             {:ok, occurrence.record}

    for expected <- expected_occurrences do
      entry = List.last(expected.record.snapshot["effects"])
      reference = entry["receipt"]
      fact_id = reference["fact_id"]

      expected_fact = %{
        version: 1,
        workflow_id: workflow_id,
        agent_id: agent_id,
        pending_revision: entry["pending_revision"],
        effect: expected.effect
      }

      {fact_index, ^reader, [^session_id, :workflow_effect_receipt, ^fact_id]} =
        one_call(reader_events, RuntimeStore, :get_fact, fn [_, _, id] -> id == fact_id end)

      assert return_after(reader_events, fact_index, reader, {RuntimeStore, :get_fact, 3}) ===
               {:ok, expected_fact}

      {aggregate_index, ^reader, [namespace, run_id]} =
        one_call(reader_events, RuntimeStore, :load, fn [_, id] ->
          id == expected.effect.locator.run_id
        end)

      assert namespace == reference["namespace"]
      assert run_id == reference["run_id"]
      assert {:ok, aggregate} = Store.load(fixture.store, run_id)

      assert return_after(reader_events, aggregate_index, reader, {RuntimeStore, :load, 2}) ===
               {:ok, aggregate}

      assert aggregate.revision == reference["final_revision"]
      assert aggregate.incarnation == reference["incarnation"]
      assert aggregate.run.expected_revision == expected.effect.receipt.final_revision

      assert aggregate.run.context.conversation.headless_result.value ===
               expected.effect.consumer_value
    end

    assert_calls_count(reader_events, RuntimeStore, :get_fact, length(expected_occurrences))
    assert_calls_count(reader_events, RuntimeStore, :load, length(expected_occurrences))

    assert Enum.filter(events, fn
             {:adapter_call, _, owner, _, _} -> owner == reader
             _ -> false
           end) == []

    for {module, function} <- [
          {Effect, :run},
          {Headless, :start_link},
          {Headless, :execute},
          {Session, :start_link},
          {CodeMode.Worker, :start_link},
          {Filesystem, :execute},
          {Filesystem, :validate_prepared_receipt},
          {Local, :prepare_target},
          {Profiles, :build},
          {Goal, :delegate},
          {Goal, :unbind},
          {ResourceRegistry, :fetch},
          {ResourceRegistry, :register},
          {RuntimeStore, :put_fact},
          {Continuations, :commit}
        ] do
      assert_calls_count(reader_events, module, function, 0)
    end
  end

  defp expected_request(workflow_id, action) do
    {request_id, tool_name, arguments} =
      case action do
        "read" ->
          {"read:1", "synapsis::read", %{"path" => "input.txt"}}

        "write" ->
          {"write:2", "synapsis::write", %{"path" => "output.txt", "content" => "one\nkeep\n"}}
      end

    %{
      correlation: %{workflow_id: workflow_id, request_id: request_id, segment: 0},
      target: %{tool_name: tool_name, tool_revision: 1, arguments: arguments},
      limits: %{
        timeout_ms: 15_000,
        effect_timeout_ms: 10_000,
        commit_timeout_ms: 5_000,
        cleanup_timeout_ms: 5_000,
        output_limit: 65_536,
        work: 4
      }
    }
  end

  defp expected_json_request(request) do
    %{
      "correlation" => %{
        "workflow_id" => request.correlation.workflow_id,
        "request_id" => request.correlation.request_id,
        "segment" => request.correlation.segment
      },
      "target" => %{
        "tool_name" => request.target.tool_name,
        "tool_revision" => request.target.tool_revision,
        "arguments" => request.target.arguments
      },
      "limits" => %{
        "timeout_ms" => 15_000,
        "effect_timeout_ms" => 10_000,
        "commit_timeout_ms" => 5_000,
        "cleanup_timeout_ms" => 5_000,
        "output_limit" => 65_536,
        "work" => 4
      }
    }
  end

  defp await_normal_exit(pid, acc) do
    receive do
      event when is_tuple(event) and elem(event, 0) == :trace ->
        case event do
          {:trace, ^pid, :exit, :normal} -> [event | acc]
          _ -> await_normal_exit(pid, [event | acc])
        end
    after
      10_000 -> flunk("actual task did not retire normally: #{inspect(pid)}")
    end
  end

  defp normal_exit_index(events, pid) do
    matches =
      for {{:trace, ^pid, :exit, :normal}, index} <- Enum.with_index(events), do: index

    assert [index] = matches
    index
  end

  defp one_call_from(events, caller, module, function, predicate) do
    matches =
      for {{:trace, ^caller, :call, {^module, ^function, args}}, index} <-
            Enum.with_index(events),
          predicate.(args),
          do: {index, caller, args}

    assert [one] = matches
    one
  end

  defp assert_calls_count(events, module, function, expected) do
    count =
      Enum.count(events, fn
        {:trace, _, :call, {^module, ^function, _}} -> true
        _ -> false
      end)

    assert count == expected
  end

  defp plain_native_term?(value) when is_map(value) and not is_struct(value),
    do:
      Enum.all?(value, fn {key, item} -> plain_native_term?(key) and plain_native_term?(item) end)

  defp plain_native_term?([]), do: true

  defp plain_native_term?([head | tail]),
    do: plain_native_term?(head) and plain_native_term?(tail)

  defp plain_native_term?(value) when is_atom(value) or is_binary(value) or is_number(value),
    do: true

  defp plain_native_term?(_), do: false

  defp assert_preparation(
         fixture,
         parent_operation,
         effect,
         bundle,
         snapshot,
         host_context,
         options,
         events
       ) do
    run_id = effect.locator.run_id
    key = {run_id, effect.locator.incarnation}
    parent_key = {fixture.identity.run_id, fixture.identity.incarnation}
    target = effect.receipt.target_intent.operation
    target_name = fixture.request.target.tool_name
    raw = fixture.request.target.arguments

    {effect_index, owner, [request, supplied]} =
      one_call(events, Effect, :run, fn [_, context] ->
        context.operation.invocation_id == parent_operation.invocation_id
      end)

    assert request === fixture.request
    assert supplied.operation === parent_operation
    assert supplied.profiles_snapshot === fixture.snapshot
    assert supplied.workflow_effect_registration === fixture.registration
    assert return_after(events, effect_index, owner, {Effect, :run, 2}) === {:ok, effect}

    assert [{register_message, ^owner, {:ok, ticket}, reserved}] =
             adapter_calls(events, :workflow_effect_register, fn message ->
               elem(message, 3).run_id == run_id
             end)

    assert elem(register_message, 1) === parent_key
    assert elem(register_message, 2).catalog === parent_operation.backend_context.catalog_snapshot
    assert elem(register_message, 2).authority === parent_operation.effective_authority
    assert elem(register_message, 4) === options[:session_binding]

    assert elem(register_message, 5) ===
             Map.take(fixture.request.target, [:tool_name, :tool_revision])

    assert reserved[parent_key].snapshot === fixture.snapshot
    assert reserved[parent_key].prepared_targets == %{}
    assert reserved[key].workflow.phase == :pending
    assert reserved[key].prepared_targets == %{}
    assert reserved[key].prepared_targets_closed?
    assert host_context.tool_filesystem === ticket.tool_filesystem

    assert [{_, ^owner, {:ok, live_host}, active}] =
             adapter_calls(events, :workflow_effect_activate, fn message ->
               elem(message, 1) == key
             end)

    assert snapshot.issued_descriptors === bundle.registry.tools
    assert active[key].snapshot === snapshot
    assert active[key].workflow.owner == owner
    assert active[key].workflow.phase == :active
    assert active[key].prepared_targets == %{}
    refute active[key].prepared_targets_closed?
    assert live_host.filesystem_preparation === ticket.preparation
    assert options[:host_context] === live_host
    assert options[:session_binding] === active[key].workflow.binding
    parent_descriptor = fixture.snapshot.issued_descriptors[target_name]

    expected_context =
      parent_descriptor.backend_context
      |> Map.merge(Map.take(target, [:run_id, :incarnation, :catalog_revision]))
      |> Map.put(:prepared_target_resolver, ticket.preparation.fetch)

    assert bundle.registry.tools[target_name] ===
             %{parent_descriptor | backend_context: expected_context}

    assert ticket.preparation.fetch !== parent_descriptor.backend_context.prepared_target_resolver

    assert [{_, _, {:ok, prepared}, sealed}] =
             adapter_calls(events, :filesystem_target_seal, fn message ->
               elem(message, 1).run_id == run_id
             end)

    assert sealed[parent_key].prepared_targets == %{}
    assert [{ledger_key, envelope}] = Map.to_list(sealed[key].prepared_targets)
    assert envelope.state == :sealed
    assert envelope.record === prepared

    assert ledger_key ===
             {run_id, target.incarnation, target.catalog_revision, target.invocation_id,
              target_name, target.tool_revision}

    assert prepared.key === ledger_key
    assert prepared.raw_arguments_digest === digest(raw)
    assert prepared.prepared_arguments_digest === digest(target.arguments)
    assert prepared.original_path === raw["path"]
    assert prepared.public_path === target.arguments["path"]
    absolute = Path.join(fixture.profiles_context.project_path, raw["path"])
    assert prepared.target === {:local, absolute, raw["path"]}
    assert prepared.resource === "filesystem:" <> absolute
    assert target.arguments === raw

    fetches =
      adapter_calls(events, :filesystem_target_fetch, fn message ->
        elem(message, 1).run_id == run_id
      end)

    assert fetches != []

    for {_, _, result, state} <- fetches do
      assert result === {:ok, prepared}
      assert state[key].prepared_targets[ledger_key].record === prepared
      assert state[parent_key].prepared_targets == %{}
    end

    {receipt_index, receipt_pid, [receipt_raw, live_operation]} =
      one_call(events, Filesystem, :validate_prepared_receipt, fn [_, operation] ->
        operation.run_id == run_id
      end)

    assert receipt_raw === raw
    assert live_operation.arguments === target.arguments
    assert live_operation.backend_context.prepared_target_resolver === ticket.preparation.fetch

    assert return_after(
             events,
             receipt_index,
             receipt_pid,
             {Filesystem, :validate_prepared_receipt, 2}
           ) === :ok

    {_, _, [executed]} =
      one_call(events, Filesystem, :execute, fn [operation] -> operation.run_id == run_id end)

    assert executed.arguments === target.arguments

    assert [{_, producer, {:ok, {:new, _}}, _}] =
             adapter_calls(events, :filesystem_target_reserve, fn message ->
               elem(message, 1).run_id == run_id
             end)

    selections =
      for {:trace, ^producer, :call, {Local, :prepare_target, arguments}} <- events,
          do: arguments

    assert [[root, path, action, environment, _]] = selections
    assert root == fixture.profiles_context.project_path
    assert path == raw["path"]
    assert action == if(target_name == "synapsis::read", do: :read, else: :write)
    assert environment === fixture.profiles_context.tool_filesystem.path_environment

    assert [{_, _, :ok, released}] =
             adapter_calls(events, :workflow_effect_release, fn message ->
               elem(message, 1) == key
             end)

    assert Map.keys(released) == [parent_key]
    assert released[parent_key].snapshot === fixture.snapshot
    assert released[parent_key].prepared_targets == %{}
    refute released[parent_key].prepared_targets_closed?
  end

  defp assert_distinct_preparations(events, count) do
    tickets =
      for {_, _, {:ok, ticket}, _} <-
            adapter_calls(events, :workflow_effect_register, fn _ -> true end),
          do: ticket

    assert length(tickets) == count

    for callback <- [:reserve, :seal, :fetch, :abandon] do
      callbacks = Enum.map(tickets, &Map.fetch!(&1.preparation, callback))
      assert Enum.all?(callbacks, &is_function/1)
      assert length(Enum.uniq(callbacks)) == count
    end
  end

  defp adapter_calls(events, action, predicate) do
    for {:adapter_call, message, owner, result, state} <- events,
        elem(message, 0) == action and predicate.(message),
        do: {message, owner, result, state}
  end

  defp digest(arguments),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(arguments, [:deterministic]))

  defp install_observation do
    for {module, _, _} = mfa <- @trace_targets do
      Code.ensure_loaded!(module)
      assert :erlang.trace_pattern(mfa, [{:_, [], [{:return_trace}]}], [:local]) > 0
    end

    on_exit(fn -> for mfa <- @trace_targets, do: :erlang.trace_pattern(mfa, false, [:local]) end)
  end

  defp drain_observation(acc) do
    receive do
      event when is_tuple(event) and elem(event, 0) in [:trace, :adapter_call] ->
        drain_observation([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp one_call(events, module, function, predicate) do
    matches =
      for {{:trace, pid, :call, {^module, ^function, args}}, index} <- Enum.with_index(events),
          predicate.(args),
          do: {index, pid, args}

    assert [one] = matches
    one
  end

  defp return_after(events, index, pid, mfa) do
    result =
      events
      |> Enum.drop(index + 1)
      |> Enum.find(fn
        {:trace, ^pid, :return_from, ^mfa, _} -> true
        _ -> false
      end)

    assert {:trace, ^pid, :return_from, ^mfa, value} = result
    value
  end

  defp cleanup_journal(session_id, namespace) do
    for prefix <- [
          "coord/runtime/facts/" <> segment(session_id) <> "/",
          "coord/runtime/runs/" <> segment(namespace) <> "/",
          "coord/workflow_continuations/" <> session_id <> "/"
        ] do
      {:ok, pairs} = Concord.Turso.prefix_scan(prefix, timeout: 5_000)
      for {key, _} <- pairs, do: Concord.Turso.delete(key, timeout: 5_000)
    end
  end

  defp segment(value), do: value |> to_string() |> Base.url_encode64(padding: false)
  defp json_value(value), do: value |> Jason.encode!() |> Jason.decode!()
end
