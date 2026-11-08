defmodule Synapsis.Agent.Tools.Workflows.EffectGoalFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Conversation, Goal}
  alias Backplane.AgentRuntime.Codex
  alias Backplane.AgentRuntime.Codex.{CodeMode, Headless, ResourceRegistry, Session}
  alias Synapsis.Agent.Runtime.{GoalStore, RunInventory, Store}
  alias Synapsis.Agent.Tools.{Catalog, Filesystem, Policy, Profiles}
  alias Synapsis.Agent.Tools.CodeMode, as: HostCodeMode
  alias Synapsis.Agent.Tools.Workflows.Effect
  alias Synapsis.Goal.Store, as: GoalDataStore
  alias Synapsis.Session.Store, as: SessionStore

  @moduletag :tmp_dir
  @moduletag timeout: 90_000
  @caller_tool "fixture_goal_workflow_effect"
  @source "// @exec: {\"yield_time_ms\": 1000}\nreturn await tools[input.tool_name](input.arguments);\n"
  @trace_targets [
    {Effect, :run, 2},
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
      :erlang.trace(self(), true, [:call, :procs, :set_on_spawn, {:tracer, observer}])

      supplied =
        context
        |> Map.take([
          :session_binding,
          :profiles_context,
          :profiles_snapshot,
          :ceiling,
          :store,
          :session_id,
          :caller
        ])
        |> Map.put(:operation, operation)

      # The actual native operation owns the Goal pair. No Goal override is
      # supplied in the trusted context passed to the product under test.
      request = Map.fetch!(context.requests, operation.arguments["effect"])
      result = Effect.run(request, supplied)
      {:ok, attribution} = Goal.attribution(context.goal, context.goal_binding)
      {:ok, durable_goal} = GoalDataStore.load(context.session_id)

      send(observer, {
        :goal_continuity,
        operation.invocation_id,
        attribution,
        durable_goal
      })

      barrier = :erlang.trace_delivered(:all)

      receive do
        {:trace_delivered, :all, ^barrier} -> :ok
      after
        5_000 -> raise "Goal native observation did not drain"
      end

      :erlang.trace(self(), false, [:call, :procs, :set_on_spawn])
      send(observer, {:workflow_effect_outcome, operation, result})

      case result do
        {:ok, effect} -> {:ok, %{value: effect.consumer_value, is_error: false}}
        error -> error
      end
    end
  end

  test "one actual parent Goal owns two fresh read children and one committed write child",
       %{tmp_dir: root} do
    File.write!(Path.join(root, "goal-read.txt"), "actual Goal read\n")
    fixture = open_fixture(root)
    install_observation()

    source = """
    // @exec: {"yield_time_ms": 10000}
    const first = await tools.fixture_goal_workflow_effect({effect: "read"});
    const second = await tools.fixture_goal_workflow_effect({effect: "read"});
    const written = await tools.fixture_goal_workflow_effect({effect: "write"});
    return [first.value, second.value, written.value];
    """

    assert {:ok, %{run_id: run_id, incarnation: 1}} = Headless.execute(fixture.parent, source)
    assert run_id == fixture.identity.run_id

    effects =
      for _ <- 1..3 do
        assert_receive {:workflow_effect_outcome, operation, {:ok, effect}}, 40_000
        {operation, effect}
      end

    for {operation, _effect} <- effects do
      invocation_id = operation.invocation_id
      assert_receive {:goal_continuity, ^invocation_id, attribution, durable_goal}, 5_000
      assert attribution === fixture.goal.binding
      assert_goal_identity(fixture, durable_goal)
    end

    assert {:ok, result} = Headless.await(fixture.parent, timeout: 20_000)
    assert_receive {:agent_runtime, ^run_id, %{type: :run_completed}}, 5_000
    assert result.status == :completed
    assert result.value == Enum.map(effects, fn {_, effect} -> effect.consumer_value end)
    assert result.nested_invocations == 3
    assert Process.alive?(fixture.session)
    assert {:ok, parent_aggregate} = Store.load(fixture.store, run_id)
    assert Map.get(parent_aggregate.run, :provider_attempts, %{}) == %{}
    assert {:ok, root_goal} = Goal.snapshot(fixture.goal.pid)
    assert {:ok, ^root_goal} = GoalDataStore.load(fixture.identity.session_id)
    assert_goal_identity(fixture, root_goal)
    events = drain_observation([])

    expected_read = %{
      content: "actual Goal read\n",
      structured: %{
        path: "goal-read.txt",
        content: "actual Goal read\n",
        offset: 0,
        next_offset: nil,
        truncated: false,
        partial_line: false
      },
      is_error: false
    }

    expected_write = %{
      content: "created: goal-draft.txt",
      structured: %{status: "created", path: "goal-draft.txt", bytes: 11},
      is_error: false
    }

    [{first_operation, first}, {second_operation, second}, {write_operation, written}] = effects
    assert first_operation.arguments === %{"effect" => "read"}
    assert second_operation.arguments === %{"effect" => "read"}
    assert write_operation.arguments === %{"effect" => "write"}
    assert_effect(fixture, {first_operation, first}, expected_read, events)
    assert_effect(fixture, {second_operation, second}, expected_read, events)
    assert_effect(fixture, {write_operation, written}, expected_write, events)
    assert first.request === second.request

    assert Enum.uniq(Enum.map(effects, fn {_, effect} -> effect.locator.run_id end)) |> length() ==
             3

    assert Enum.uniq(Enum.map(effects, fn {op, _} -> op.invocation_id end)) |> length() == 3

    assert Enum.uniq(Enum.map(effects, fn {_, effect} -> effect.retirement.resource_handle end))
           |> length() == 3

    assert File.read!(Path.join(root, "goal-read.txt")) == "actual Goal read\n"
    assert File.read!(Path.join(root, "goal-draft.txt")) == "goal\nproof\n"
    assert_retained_without_replay(fixture, effects)
    assert File.read!(Path.join(root, "goal-read.txt")) == "actual Goal read\n"
    assert File.read!(Path.join(root, "goal-draft.txt")) == "goal\nproof\n"
  end

  defp open_fixture(root) do
    assert :ok = SessionStore.ensure_started()
    session_id = Ecto.UUID.generate()
    run_id = Ecto.UUID.generate()
    caller = "synapsis:" <> session_id
    names = ["exec", "wait", "synapsis::file_read", "synapsis::file_write"]
    all_names = names ++ [@caller_tool]
    assert {:ok, store} = Store.new(1)

    assert {:ok, agent} =
             Synapsis.AgentConfigs.create(%{
               name: "goal-workflow-effect-#{session_id}",
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

    profiles_context = %{
      session: %{id: session_id, config: %{"subagents" => false}},
      agent: %{name: agent.name, tools: names, tool_contract_version: 1},
      project_path: root
    }

    assert {:ok, %{bundle: original, snapshot: snapshot}} =
             Profiles.build(profiles_context, identity, native, ceiling)

    assert snapshot.permission === permission
    assert Enum.sort(Map.keys(snapshot.issued_descriptors)) == Enum.sort(names)
    assert original.registry.tools["exec"].backend == Codex.Backend

    limits = %{
      timeout_ms: 15_000,
      effect_timeout_ms: 10_000,
      commit_timeout_ms: 5_000,
      cleanup_timeout_ms: 5_000,
      output_limit: 65_536,
      work: 4
    }

    workflow_id = Ecto.UUID.generate()

    requests = %{
      "read" => %{
        correlation: %{workflow_id: workflow_id, request_id: "goal-read-effect", segment: 0},
        target: %{
          tool_name: "synapsis::file_read",
          tool_revision: 1,
          arguments: %{"path" => "goal-read.txt"}
        },
        limits: limits
      },
      "write" => %{
        correlation: %{workflow_id: workflow_id, request_id: "goal-write-effect", segment: 1},
        target: %{
          tool_name: "synapsis::file_write",
          tool_revision: 1,
          arguments: %{"path" => "goal-draft.txt", "content" => "goal\nproof\n"}
        },
        limits: limits
      }
    }

    descriptor = %{
      tool_name: @caller_tool,
      tool_revision: 1,
      backend: StrictCallerBackend,
      backend_context: %{
        observer: self(),
        requests: requests,
        session_binding: binding,
        profiles_context: profiles_context,
        profiles_snapshot: snapshot,
        ceiling: ceiling,
        store: store,
        session_id: session_id,
        caller: caller
      },
      schema: %{
        "type" => "object",
        "properties" => %{"effect" => %{"type" => "string", "enum" => ["read", "write"]}},
        "required" => ["effect"],
        "additionalProperties" => false
      },
      safety: %{read_only: false, retry_safe: false, parallel_safe: false}
    }

    assert {:ok, catalog} = Catalog.compose([original], [descriptor], ceiling, all_names)

    for name <- names,
        do: assert(catalog.registry.tools[name] === snapshot.issued_descriptors[name])

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
      goal: goal,
      session: session,
      binding: binding,
      identity: identity,
      names: names,
      requests: requests,
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
    assert parent_operation.backend_context.profiles_snapshot === fixture.snapshot
    assert parent_operation.backend_context.ceiling === fixture.ceiling
    assert {:ok, aggregate} = Store.load(fixture.store, locator.run_id)
    record = aggregate.run
    receipt = effect.receipt
    outer = receipt.outer_intent.operation
    target = receipt.target_intent.operation
    assert record.state == :completed
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

    assert Map.take(host_context, [:session, :agent, :project_path]) === expected_profiles

    assert {:ok, %{bundle: bundle, snapshot: snapshot}} =
             return_after(events, build_index, build_pid, {Profiles, :build, 4})

    assert snapshot.permission === fixture.snapshot.permission
    assert snapshot.evidence === fixture.snapshot.evidence
    assert Enum.sort(Map.keys(bundle.registry.tools)) == Enum.sort(fixture.names)
    assert options[:registry] === bundle.registry
    assert options[:tools] === bundle.tools
    assert options[:authority] === bundle.authority
    assert_native_goal(fixture, parent_operation, effect, child, options, events)

    assert {:ok, original_filesystem} =
             Filesystem.descriptors(%{
               root: host_context.project_path,
               run_id: run_id,
               incarnation: 1,
               catalog_revision: 1,
               workspace: %{
                 role: :session,
                 agent_id: host_context.agent.name,
                 session_id: fixture.identity.session_id
               }
             })

    assert bundle.registry.tools[fixture.request.target.tool_name] ===
             Enum.find(original_filesystem, &(&1.tool_name == fixture.request.target.tool_name))

    assert identity.caller == fixture.identity.caller

    {_, _, [_, projected_snapshot, pinned]} =
      one_call(events, Profiles, :project_catalog, fn [op, _, _] ->
        op.run_id == run_id and op.tool_name == fixture.request.target.tool_name
      end)

    assert projected_snapshot === snapshot
    assert pinned.registry === bundle.registry

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

  defp assert_retained_without_replay(fixture, effects) do
    before =
      Map.new(effects, fn {_, effect} ->
        assert {:ok, aggregate} = Store.load(fixture.store, effect.locator.run_id)
        {effect.locator.run_id, aggregate}
      end)

    assert {:ok, %{coverage: :retained_only, entries: entries}} =
             RunInventory.load(fixture.identity.session_id)

    assert length(entries) == length(effects)

    for {_, effect} <- effects do
      entry = Enum.find(entries, &(&1.locator == effect.locator))
      assert entry.availability == :present
      assert entry.aggregate === before[effect.locator.run_id]
    end

    assert {:ok, %{status: :confirmed}} = Session.close(fixture.session)

    for {run_id, aggregate} <- before,
        do: assert(Store.load(fixture.store, run_id) === {:ok, aggregate})

    assert {:ok, %{entries: ^entries}} = RunInventory.load(fixture.identity.session_id)
  end

  defp install_observation do
    for {module, _, _} = mfa <- @trace_targets do
      Code.ensure_loaded!(module)
      assert :erlang.trace_pattern(mfa, [{:_, [], [{:return_trace}]}], [:local]) > 0
    end

    on_exit(fn -> for mfa <- @trace_targets, do: :erlang.trace_pattern(mfa, false, [:local]) end)
  end

  defp drain_observation(acc) do
    receive do
      event when is_tuple(event) and elem(event, 0) == :trace -> drain_observation([event | acc])
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
          "coord/runtime/runs/" <> segment(namespace) <> "/"
        ] do
      {:ok, pairs} = Concord.Turso.prefix_scan(prefix, timeout: 5_000)
      for {key, _} <- pairs, do: Concord.Turso.delete(key, timeout: 5_000)
    end
  end

  defp segment(value), do: value |> to_string() |> Base.url_encode64(padding: false)
  defp json_value(value), do: value |> Jason.encode!() |> Jason.decode!()
end
