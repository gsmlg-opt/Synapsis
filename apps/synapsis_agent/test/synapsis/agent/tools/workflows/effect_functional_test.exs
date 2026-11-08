defmodule Synapsis.Agent.Tools.Workflows.EffectFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex
  alias Backplane.AgentRuntime.Codex.{CodeMode, Headless, ResourceRegistry, Session}
  alias Synapsis.Agent.Runtime.{RunInventory, SessionAdapter, Store}
  alias Synapsis.Agent.Tools.{Catalog, Filesystem, Policy, Profiles}
  alias Synapsis.Agent.Tools.CodeMode, as: HostCodeMode
  alias Synapsis.Agent.Tools.Workflows.Effect
  alias Synapsis.Filesystem.Local
  alias Synapsis.Session.Store, as: SessionStore

  @moduletag :tmp_dir
  @moduletag timeout: 90_000
  @node "/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node"
  @caller_tool "fixture_workflow_effect"
  @source "// @exec: {\"yield_time_ms\": 1000}\nreturn await tools[input.tool_name](input.arguments);\n"
  @trace_targets [
    {Effect, :run, 2},
    {Filesystem, :execute, 1},
    {Filesystem, :validate_prepared_receipt, 2},
    {Local, :prepare_target, 5},
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
  defmodule CallerBackend do
    def execute(operation) do
      context = operation.backend_context
      observer = context.observer
      :erlang.trace(self(), true, [:call, :procs, :set_on_spawn, {:tracer, observer}])

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

      result = Effect.run(context.request, supplied)
      barrier = :erlang.trace_delivered(:all)

      receive do
        {:trace_delivered, :all, ^barrier} -> :ok
      after
        5_000 -> raise "ordinary native observation did not drain"
      end

      :erlang.trace(self(), false, [:call, :procs, :set_on_spawn])
      send(observer, {:workflow_effect_outcome, operation, result})

      case result do
        {:ok, effect} -> {:ok, %{value: effect.consumer_value, is_error: false}}
        error -> error
      end
    end
  end

  test "two ordinary reads preserve exact arguments/results and allocate fresh owned native children",
       %{tmp_dir: root} do
    File.write!(Path.join(root, "read.txt"), "native workflow read\n")

    expected = %{
      content: [%{type: "text", text: "native workflow read\n"}],
      details: %{kind: "text", content: "native workflow read\n"},
      is_error: false
    }

    {fixture, effects, events} = exercise(root, "synapsis::read", %{"path" => "read.txt"}, 2)
    Enum.each(effects, &assert_effect(fixture, &1, expected, events))
    [{first_operation, first}, {second_operation, second}] = effects
    assert first.request === second.request
    assert first.locator.run_id != second.locator.run_id
    assert first_operation.invocation_id != second_operation.invocation_id

    assert first.receipt.outer_intent.operation.invocation_id !=
             second.receipt.outer_intent.operation.invocation_id

    assert first.receipt.target_intent.operation.invocation_id !=
             second.receipt.target_intent.operation.invocation_id

    assert first.retirement.resource_handle != second.retirement.resource_handle
    assert File.read!(Path.join(root, "read.txt")) == "native workflow read\n"
    assert_retained_without_replay(fixture, effects)
    assert File.read!(Path.join(root, "read.txt")) == "native workflow read\n"
  end

  test "one ordinary write returns the original committed result and leaves actual file bytes",
       %{tmp_dir: root} do
    arguments = %{"path" => "draft.txt", "content" => "one\nkeep\n"}

    expected = %{
      content: [%{type: "text", text: "Successfully wrote 9 bytes to draft.txt"}],
      details: %{
        diff: "+1 one\n+2 keep",
        firstChangedLine: 1,
        patch: "--- draft.txt\n+++ draft.txt\n@@ -0,0 +1,2 @@\n+one\n+keep\n",
        changed: true,
        created: true
      },
      is_error: false
    }

    {fixture, effects, events} = exercise(root, "synapsis::write", arguments, 1)
    Enum.each(effects, &assert_effect(fixture, &1, expected, events))
    assert File.read!(Path.join(root, "draft.txt")) == "one\nkeep\n"
    assert_retained_without_replay(fixture, effects)
    assert File.read!(Path.join(root, "draft.txt")) == "one\nkeep\n"
  end

  defp exercise(root, target, arguments, count) do
    install_observation()
    fixture = open_fixture(root, target, arguments)

    source =
      "// @exec: {\"yield_time_ms\": 10000}\n" <>
        "const values = [];\n" <>
        Enum.map_join(1..count, "\n", fn _ ->
          "values.push((await tools.fixture_workflow_effect({})).value);"
        end) <> "\nreturn values;\n"

    assert {:ok, %{run_id: run_id, incarnation: 1}} = Headless.execute(fixture.parent, source)
    assert run_id == fixture.identity.run_id

    effects =
      for _ <- 1..count do
        assert_receive {:workflow_effect_outcome, operation, {:ok, effect}}, 40_000
        {operation, effect}
      end

    assert {:ok, result} = Headless.await(fixture.parent, timeout: 20_000)
    assert result.status == :completed
    assert result.value == Enum.map(effects, fn {_, effect} -> effect.consumer_value end)
    assert result.nested_invocations == count
    assert Process.alive?(fixture.session)
    assert {:ok, parent_aggregate} = Store.load(fixture.store, run_id)
    assert Map.get(parent_aggregate.run, :provider_attempts, %{}) == %{}
    events = drain_observation([])
    assert_distinct_preparations(events, count)

    for {module, function} <- [{Effect, :run}, {Filesystem, :execute}, {Local, :prepare_target}] do
      assert Enum.count(events, fn
               {:trace, _, :call, {^module, ^function, _}} -> true
               _ -> false
             end) == count
    end

    {fixture, effects, events}
  end

  defp open_fixture(root, target, arguments) do
    assert File.regular?(@node)
    assert :ok = SessionStore.ensure_started()
    session_id = Ecto.UUID.generate()
    run_id = Ecto.UUID.generate()
    caller = "synapsis:" <> session_id
    names = ["exec", "wait", target]
    all_names = names ++ [@caller_tool]
    assert {:ok, store} = Store.new(1)

    assert {:ok, agent} =
             Synapsis.AgentConfigs.create(%{
               name: "workflow-effect-#{session_id}",
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
    assert Enum.sort(Map.keys(snapshot.issued_descriptors)) == Enum.sort(names)
    assert original.registry.tools["exec"].backend == Codex.Backend

    request = %{
      correlation: %{
        workflow_id: Ecto.UUID.generate(),
        request_id: "ordinary-native-effect",
        segment: 0
      },
      target: %{tool_name: target, tool_revision: 1, arguments: arguments},
      limits: %{
        timeout_ms: 15_000,
        effect_timeout_ms: 10_000,
        commit_timeout_ms: 5_000,
        cleanup_timeout_ms: 5_000,
        output_limit: 65_536,
        work: 4
      }
    }

    registration = SessionAdapter.workflow_effect_registration(adapter, run_id, 1)

    descriptor = %{
      tool_name: @caller_tool,
      tool_revision: 1,
      backend: CallerBackend,
      backend_context: %{
        observer: self(),
        adapter: adapter,
        workflow_effect_registration: registration,
        request: request,
        session_binding: binding,
        profiles_context: profiles_context,
        ceiling: ceiling,
        store: store,
        session_id: session_id,
        caller: caller
      },
      schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
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
      session: session,
      binding: binding,
      identity: identity,
      names: names,
      request: request,
      store: store,
      snapshot: snapshot,
      profiles_context: profiles_context,
      ceiling: ceiling
    }
  end

  defp assert_effect(fixture, {parent_operation, effect}, expected, events) do
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

    assert Map.take(host_context, [:session, :agent, :project_path]) ===
             Map.take(fixture.profiles_context, [:session, :agent, :project_path])

    assert {:ok, %{bundle: bundle, snapshot: snapshot}} =
             return_after(events, build_index, build_pid, {Profiles, :build, 4})

    assert snapshot.permission === fixture.snapshot.permission
    assert snapshot.evidence === fixture.snapshot.evidence
    assert Enum.sort(Map.keys(bundle.registry.tools)) == Enum.sort(fixture.names)
    assert options[:registry] === bundle.registry
    assert options[:tools] === bundle.tools
    assert options[:authority] === bundle.authority

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
          "coord/runtime/runs/" <> segment(namespace) <> "/"
        ] do
      {:ok, pairs} = Concord.Turso.prefix_scan(prefix, timeout: 5_000)
      for {key, _} <- pairs, do: Concord.Turso.delete(key, timeout: 5_000)
    end
  end

  defp segment(value), do: value |> to_string() |> Base.url_encode64(padding: false)
  defp json_value(value), do: value |> Jason.encode!() |> Jason.decode!()
end
