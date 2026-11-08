defmodule Synapsis.Agent.Tools.Workflows.SegmentJournalFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex.{CodeMode, Headless, ResourceRegistry, Session}
  alias Synapsis.Agent.Runtime.{SessionAdapter, Store}
  alias Synapsis.Agent.Tools.{Catalog, Filesystem, Policy, Profiles}
  alias Synapsis.Agent.Tools.CodeMode, as: HostCodeMode
  alias Synapsis.Agent.Tools.Workflows.{Effect, Journal}
  alias Synapsis.Filesystem.Local
  alias Synapsis.Runtime.Store, as: RuntimeStore
  alias Synapsis.Session.Store, as: SessionStore
  alias Synapsis.Workflow.{Continuations, Machine, Segment}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @node "/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node"
  @caller_tool "fixture_segment_workflow"
  @names ~w(exec wait synapsis::read synapsis::write synapsis::edit synapsis::ls)
  @source "// @exec: {\"yield_time_ms\": 1000}\nreturn await tools[input.tool_name](input.arguments);\n"
  @first ~S({"content":[{"type":"text","text":"first\n"}],"details":{"kind":"text","content":"first\n"}})
  @second ~S({"details":{"content":"second\n","kind":"text"},"content":[{"text":"second\n","type":"text"}]})
  @pipeline ~S(openclaw.invoke --tool synapsis::read --action read --args-json '{"path":"first.txt"}' | clawd.invoke --tool synapsis::read --action read --args-json '{"path":"second.txt"}')
  @trace_targets [
    {Effect, :run, 2},
    {Filesystem, :execute, 1},
    {Filesystem, :validate_prepared_receipt, 2},
    {Local, :prepare_target, 5},
    {Profiles, :build, 4},
    {Headless, :start_link, 1},
    {Headless, :execute, 3},
    {Session, :start_link, 1},
    {ResourceRegistry, :register, 5},
    {ResourceRegistry, :release, 3},
    {CodeMode.Worker, :os_identity, 1},
    {RuntimeStore, :put_fact, 4},
    {Continuations, :commit, 5},
    {Segment, :prepare_effect, 4},
    {Segment, :consume_effect, 4}
  ]

  # Bounded observation wrapper copied from the canonical native fixture. It
  # holds genuine Profiles snapshots and delegates production adapter handlers.
  # This is an admitted fixture caller, not production Worker/options admission
  # or a public Workflow caller/transport mapping.
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

    def handle_call({:install_root, key, snapshot}, _, state) do
      entry = %{
        snapshot: snapshot,
        discovery: nil,
        prepared_targets: %{},
        prepared_target_bytes: 0,
        prepared_targets_closed?: false
      }

      {:reply, :ok, %{state | tool_contexts: %{key => entry}}}
    end

    def handle_call({:root_snapshot, key}, _, state),
      do: {:reply, state.tool_contexts[key].snapshot, state}

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

  defmodule CallerBackend do
    def execute(operation) do
      context = operation.backend_context
      trace(context.observer)

      snapshot =
        GenServer.call(
          context.adapter,
          {:root_snapshot, {operation.run_id, operation.incarnation}},
          5_000
        )

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

      before_parent = parent_state(operation)

      {:ok, %{deadline_ms: deadline}} = operation.backend_context.effect_deadline.()
      {:ok, initial_snapshot} = Segment.new(context.pipeline, version: 2)

      {:ok, initial} =
        Continuations.create(
          context.session_id,
          context.profiles_context.agent.id,
          initial_snapshot,
          deadline: deadline
        )

      {record, steps} =
        Enum.reduce(context.steps, {initial, []}, fn step, {record, steps} ->
          {:request, request, awaiting} = boundary(record.snapshot)
          # The caller explicitly supplies each native target. It does not derive
          # native tool selection or raw result JSON from the Machine request.
          native = %{
            correlation: %{
              workflow_id: record.id,
              request_id: request["id"],
              segment: request["segment"]
            },
            target: step.target,
            limits: %{
              timeout_ms: 20_000,
              effect_timeout_ms: 15_000,
              commit_timeout_ms: 5_000,
              cleanup_timeout_ms: 5_000,
              output_limit: 65_536,
              work: 4
            }
          }

          {:ok, %{record: settled, effect: effect}} =
            Journal.run_segment(record, awaiting, native, supplied)

          {:ok, %{record: consumed, effect: ^effect}} =
            Journal.consume_segment(settled, step.raw, supplied)

          observation = %{
            before: record,
            awaiting: awaiting,
            request: request,
            native: native,
            settled: settled,
            consumed: consumed,
            effect: effect,
            raw: step.raw
          }

          {consumed, steps ++ [observation]}
        end)

      {:complete, _, completed} = boundary(record.snapshot)
      after_parent = parent_state(operation)
      drain_trace()
      :erlang.trace(self(), false, [:call, :procs, :set_on_spawn])

      send(
        context.observer,
        {:segment_outcome, self(), operation, initial, record, completed, steps, before_parent,
         after_parent}
      )

      {:ok, %{value: Enum.map(steps, & &1.effect.consumer_value), is_error: false}}
    end

    def trace(observer),
      do: :erlang.trace(self(), true, [:call, :procs, :set_on_spawn, {:tracer, observer}])

    def drain_trace do
      barrier = :erlang.trace_delivered(:all)

      receive do
        {:trace_delivered, :all, ^barrier} -> :ok
      after
        5_000 -> raise "Segment Workflow trace did not drain"
      end
    end

    defp boundary(snapshot, remaining \\ 10_000)
    defp boundary(_, 0), do: raise("ordinary Segment transition helper exhausted")

    defp boundary(snapshot, remaining) do
      case Segment.advance(snapshot) do
        {:continue, next} -> boundary(next, remaining - 1)
        other -> other
      end
    end

    defp parent_state(operation) do
      context = operation.backend_context

      %{
        owner: context.resource_owner_pid,
        owner_alive: Process.alive?(context.resource_owner_pid),
        session_alive: Process.alive?(context.session_binding.session),
        validation: Session.validate(context.session_binding, operation)
      }
    end
  end

  test "one UUID acknowledges two real native effects, consumes in order and reopens read only",
       %{tmp_dir: root} do
    files = Path.join(root, "files")
    File.mkdir!(files)
    File.write!(Path.join(files, "first.txt"), "first\n")
    File.write!(Path.join(files, "second.txt"), "second\n")
    fixture = open_fixture(root, files)
    install_observation()

    source =
      "// @exec: {\"yield_time_ms\": 10000}\nreturn (await tools.fixture_segment_workflow({})).value;\n"

    assert {:ok, %{run_id: run_id}} = Headless.execute(fixture.parent, source)
    assert run_id == fixture.identity.run_id

    assert_receive {:segment_outcome, writer, operation, initial, record, completed, steps,
                    before_parent, after_parent},
                   80_000

    assert {:ok, result} = Headless.await(fixture.parent, timeout: 20_000)
    assert result.status == :completed
    assert result.value === [Jason.decode!(@first), Jason.decode!(@second)]
    assert result.nested_invocations == 1
    assert result.output == []
    refute result.output_truncated
    refute Process.alive?(writer)
    assert Process.alive?(fixture.parent)
    assert Process.alive?(fixture.session)
    assert before_parent === after_parent
    assert before_parent.owner == fixture.parent
    assert before_parent.owner_alive
    assert before_parent.session_alive
    assert {:ok, _} = before_parent.validation
    assert Map.keys(:sys.get_state(fixture.adapter).tool_contexts) == [{run_id, 1}]
    assert initial.revision == 1
    assert initial.snapshot["version"] == 2
    assert initial.snapshot["consumed_effects"] == 0
    assert initial.snapshot["journal"]["effects"] == []
    assert [first, second] = steps
    assert first.before === initial
    assert second.before === first.consumed
    assert first.awaiting["machine"] !== initial.snapshot["machine"]
    assert first.awaiting["revision"] == 1
    assert second.awaiting["revision"] == 4
    assert record === second.consumed
    assert record.id == initial.id
    assert record.revision == 7
    assert record.snapshot["revision"] == 7
    assert record.snapshot["consumed_effects"] == 2
    assert completed["journal"] === record.snapshot["journal"]
    assert completed["consumed_effects"] == 2
    assert {:ok, %{"status" => "ok", "output" => [value]}} = Segment.envelope(completed, "unused")
    assert value === Jason.decode!(@second)
    assert File.read!(Path.join(files, "first.txt")) == "first\n"
    assert File.read!(Path.join(files, "second.txt")) == "second\n"
    events = drain_observation([])
    assert length(for {:trace, _, :call, {Effect, :run, _}} <- events, do: :called) == 2
    assert length(for {:trace, _, :call, {Filesystem, :execute, _}} <- events, do: :called) == 2
    assert first.effect.locator.run_id != second.effect.locator.run_id
    assert first.effect.retirement.resource_handle != second.effect.retirement.resource_handle

    [first_order, second_order] =
      for {step, ordinal} <- Enum.with_index(steps) do
        assert_step(fixture, operation, initial.id, step, ordinal, events)
      end

    assert first_order.consumed_ack < second_order.pending_call

    assert hd(record.snapshot["journal"]["effects"]) ===
             hd(first.settled.snapshot["journal"]["effects"])

    assert {:ok, ^record} =
             Continuations.load(record.session_id, record.id, deadline: now() + 15_000)

    assert {:ok, parent_aggregate} = Store.load(fixture.store, run_id)
    assert parent_aggregate.run.state == :completed
    assert Map.get(parent_aggregate.run, :provider_attempts, %{}) == %{}
    assert_fresh_reopen(fixture, writer, record, steps)
    assert {:ok, %{status: :confirmed}} = Session.close(fixture.session)
  end

  defp assert_step(fixture, parent_operation, workflow_id, step, ordinal, events) do
    pending_revision = 2 + ordinal * 3
    request_id = "invoke:" <> Integer.to_string(ordinal + 1)
    path = if ordinal == 0, do: "first.txt", else: "second.txt"
    text = if ordinal == 0, do: "first\n", else: "second\n"

    assert step.request == %{
             "id" => request_id,
             "kind" => "invoke",
             "command" => if(ordinal == 0, do: "openclaw.invoke", else: "clawd.invoke"),
             "segment" => 0,
             "stage_index" => ordinal,
             "body" => ~s({"tool":"synapsis::read","action":"read","args":{"path":"#{path}"}})
           }

    assert step.native.correlation == %{
             workflow_id: workflow_id,
             request_id: request_id,
             segment: 0
           }

    assert step.native.target == %{
             tool_name: "synapsis::read",
             tool_revision: 1,
             arguments: %{"path" => path}
           }

    assert step.effect.request === step.native
    assert step.effect.consumer_value === Jason.decode!(step.raw)
    assert step.raw == if(ordinal == 0, do: @first, else: @second)
    assert step.settled.id == workflow_id
    assert step.consumed.id == workflow_id
    assert step.settled.revision == pending_revision + 1
    assert step.consumed.revision == pending_revision + 2
    assert step.settled.snapshot["machine"] === step.awaiting["machine"]
    assert step.settled.snapshot["consumed_effects"] == ordinal
    assert step.consumed.snapshot["consumed_effects"] == ordinal + 1
    assert step.consumed.snapshot["journal"] === step.settled.snapshot["journal"]

    assert {:continue, expected_machine} =
             Machine.advance(step.awaiting["machine"], %{
               "id" => request_id,
               "response_json" => step.raw
             })

    assert step.consumed.snapshot["machine"] === expected_machine
    assert step.consumed.snapshot["machine"]["pending_request"] == nil
    assert {:ok, %{consumed_effects: cursor}} = Segment.inspect_snapshot(step.consumed.snapshot)
    assert cursor == ordinal + 1

    {pending_call, pending_pid, [session_id, ^workflow_id, revision, pending, _]} =
      one_call(events, Continuations, :commit, fn [_, id, revision, _, _] ->
        id == workflow_id and revision == pending_revision - 1
      end)

    assert session_id == fixture.identity.session_id
    assert revision == step.before.revision
    assert pending["machine"] === step.awaiting["machine"]
    assert pending["revision"] == pending_revision
    assert pending["consumed_effects"] == ordinal
    entry = List.last(pending["journal"]["effects"])
    assert entry["state"] == "pending"
    assert entry["pending_revision"] == pending_revision

    assert entry["request"]["correlation"] == %{
             "workflow_id" => workflow_id,
             "request_id" => request_id,
             "segment" => 0
           }

    {pending_ack, {:ok, acknowledged}} =
      returned(events, pending_call, pending_pid, {Continuations, :commit, 5})

    assert acknowledged.snapshot === pending
    assert acknowledged.revision == pending_revision

    {effect_call, _, [native, _]} =
      one_call(events, Effect, :run, fn [request, _] ->
        request.correlation.request_id == request_id
      end)

    assert native === step.native
    assert pending_ack < effect_call

    effect = step.effect
    child_run = effect.locator.run_id
    assert effect.locator.parent_run_id == fixture.identity.run_id
    assert effect.locator.parent_invocation_id == parent_operation.invocation_id
    assert {:ok, aggregate} = Store.load(fixture.store, child_run)
    assert aggregate.run.state == :completed
    assert aggregate.revision == effect.receipt.final_revision
    intents = Map.values(aggregate.run.execution_intents)

    assert Enum.filter(intents, &(&1.operation.tool_name == "synapsis::read")) ===
             [effect.receipt.target_intent]

    assert Enum.filter(intents, &(&1.operation.tool_name == "exec")) ===
             [effect.receipt.outer_intent]

    for intent <- intents -- [effect.receipt.target_intent, effect.receipt.outer_intent] do
      assert intent.operation.tool_name == "wait"
      assert intent.type == :tool
      assert intent.status == :consumed
    end

    assert Enum.sort(Map.keys(aggregate.run.tool_results)) ===
             Enum.sort(Enum.map(intents, & &1.operation.invocation_id))

    assert Map.get(aggregate.run, :provider_attempts, %{}) == %{}
    target = effect.receipt.target_intent.operation
    assert target.tool_name == "synapsis::read"
    assert target.arguments === %{"path" => path}

    assert effect.receipt.target_result === %{
             content: [%{type: "text", text: text}],
             details: %{kind: "text", content: text},
             is_error: false
           }

    assert aggregate.run.tool_results[target.invocation_id] === effect.receipt.target_result
    assert effect.receipt.target_intent.status == :consumed
    assert effect.receipt.outer_intent.status == :consumed
    assert effect.receipt.outer_intent.operation.arguments == @source

    {build_index, build_pid, [_, identity, _, _]} =
      one_call(events, Profiles, :build, fn [_, identity, _, _] ->
        identity.run_id == child_run
      end)

    assert identity.session_id == session_id

    {_, {:ok, %{bundle: bundle}}} =
      returned(events, build_index, build_pid, {Profiles, :build, 4})

    assert Enum.sort(Map.keys(bundle.registry.tools)) == Enum.sort(~w(exec wait synapsis::read))

    {start_index, start_pid, [options]} =
      one_call(events, Headless, :start_link, fn [options] -> options[:run_id] == child_run end)

    {_, {:ok, child}} = returned(events, start_index, start_pid, {Headless, :start_link, 1})
    assert options[:hooks] == Policy
    assert options[:registry] === bundle.registry
    assert options[:tools] === bundle.tools
    assert options[:authority] === bundle.authority
    assert options[:session_binding].session != fixture.session
    assert options[:session_binding].resource_registry != fixture.binding.resource_registry

    {_, _, [^child, @source, execution]} =
      one_call(events, Headless, :execute, fn [pid, _, _] -> pid == child end)

    assert execution === [
             input: %{"tool_name" => "synapsis::read", "arguments" => %{"path" => path}}
           ]

    {receipt_index, receipt_pid, [raw, _]} =
      one_call(events, Filesystem, :validate_prepared_receipt, fn [_, op] ->
        op.run_id == child_run
      end)

    assert raw === step.native.target.arguments

    {_, :ok} =
      returned(events, receipt_index, receipt_pid, {Filesystem, :validate_prepared_receipt, 2})

    {_, _, [executed]} =
      one_call(events, Filesystem, :execute, fn [op] -> op.run_id == child_run end)

    assert executed.arguments === %{"path" => path}

    registry = fixture.binding.resource_registry
    handle = effect.retirement.resource_handle

    {release_index, release_pid, [^registry, ^handle, owner_id]} =
      one_call(events, ResourceRegistry, :release, fn [r, h, _] ->
        r == registry and h == handle
      end)

    assert owner_id == fixture.binding.owner_id

    {release_ack, {:ok, :ok}} =
      returned(events, release_index, release_pid, {ResourceRegistry, :release, 3})

    assert effect.retirement === %{
             resource_handle: handle,
             release: :confirmed,
             headless: :normal,
             session: :normal,
             registry: :normal
           }

    assert {:ok, %{status: :confirmed}} =
             ResourceRegistry.cleanup_status(registry, handle, owner_id)

    assert receipt_index < release_index

    for pid <- [
          child,
          options[:session_binding].session,
          options[:session_binding].resource_registry
        ] do
      assert Enum.any?(events, &match?({:trace, ^pid, :exit, :normal}, &1))
      refute Process.alive?(pid)
    end

    child_registry = options[:session_binding].resource_registry

    {_, _, [^child_registry, _, :continuation, worker, _]} =
      one_call(events, ResourceRegistry, :register, fn [r, _, kind, _, _] ->
        r == child_registry and kind == :continuation
      end)

    refute Process.alive?(worker)
    assert Enum.any?(events, &match?({:trace, ^worker, :exit, :normal}, &1))

    identities =
      for {{:trace, caller, :call, {CodeMode.Worker, :os_identity, [^worker]}}, index} <-
            Enum.with_index(events) do
        {_, {:ok, identity}} = returned(events, index, caller, {CodeMode.Worker, :os_identity, 1})
        identity
      end

    assert [os_identity, same_identity] = identities
    assert os_identity === same_identity
    refute File.exists?("/proc/#{os_identity.pid}")

    settled_entry = List.last(step.settled.snapshot["journal"]["effects"])
    reference = settled_entry["receipt"]

    assert settled_entry ===
             Map.merge(entry, %{
               "state" => "settled",
               "settled_revision" => pending_revision + 1,
               "receipt" => reference
             })

    {fact_call, fact_pid, [^session_id, :workflow_effect_receipt, fact_id, fact]} =
      one_call(events, RuntimeStore, :put_fact, fn [_, kind, id, _] ->
        kind == :workflow_effect_receipt and id == reference["fact_id"]
      end)

    assert fact_id == workflow_id <> ":" <> Integer.to_string(pending_revision)

    assert fact === %{
             version: 1,
             workflow_id: workflow_id,
             agent_id: step.settled.agent_id,
             pending_revision: pending_revision,
             effect: effect
           }

    {fact_ack, :ok} = returned(events, fact_call, fact_pid, {RuntimeStore, :put_fact, 4})
    assert release_ack < fact_call

    {settled_call, settled_pid, [_, _, _, settled_snapshot, _]} =
      one_call(events, Continuations, :commit, fn [_, id, revision, _, _] ->
        id == workflow_id and revision == pending_revision
      end)

    {settled_ack, {:ok, settled_record}} =
      returned(events, settled_call, settled_pid, {Continuations, :commit, 5})

    assert fact_ack < settled_call
    assert settled_snapshot === step.settled.snapshot
    assert settled_record === step.settled

    {consumed_call, consumed_pid, [_, _, _, consumed_snapshot, _]} =
      one_call(events, Continuations, :commit, fn [_, id, revision, _, _] ->
        id == workflow_id and revision == pending_revision + 1
      end)

    {consumed_ack, {:ok, consumed_record}} =
      returned(events, consumed_call, consumed_pid, {Continuations, :commit, 5})

    assert settled_ack < consumed_call
    assert consumed_snapshot === step.consumed.snapshot
    assert consumed_record === step.consumed
    %{pending_call: pending_call, consumed_ack: consumed_ack}
  end

  defp assert_fresh_reopen(fixture, writer, record, steps) do
    retained =
      for step <- steps do
        reference = List.last(step.settled.snapshot["journal"]["effects"])["receipt"]

        assert {:ok, fact} =
                 RuntimeStore.get_fact(
                   record.session_id,
                   :workflow_effect_receipt,
                   reference["fact_id"]
                 )

        assert fact.effect === step.effect
        assert {:ok, aggregate} = Store.load(fixture.store, step.effect.locator.run_id)
        {reference, fact, aggregate}
      end

    observer = self()

    task =
      Task.async(fn ->
        CallerBackend.trace(observer)

        result =
          Journal.reopen_segment(record.session_id, record.agent_id, record.id, record.revision,
            deadline: now() + 15_000
          )

        CallerBackend.drain_trace()
        :erlang.trace(self(), false, [:call, :procs, :set_on_spawn])
        {self(), result}
      end)

    assert {reader, {:ok, reopened}} = Task.await(task, 20_000)
    assert reader != writer
    refute Process.alive?(writer)
    assert reopened.record === record
    assert Enum.map(reopened.entries, & &1.effect) === Enum.map(steps, & &1.effect)
    assert Enum.map(reopened.entries, & &1.state) == [:settled, :settled]

    for {reference, fact, aggregate} <- retained do
      assert RuntimeStore.get_fact(
               record.session_id,
               :workflow_effect_receipt,
               reference["fact_id"]
             ) === {:ok, fact}

      assert Store.load(fixture.store, reference["run_id"]) === {:ok, aggregate}
    end

    assert Enum.filter(drain_observation([]), fn
             {:trace, _, :call, {module, function, _}} ->
               {module, function} in [
                 {Effect, :run},
                 {Filesystem, :execute},
                 {Local, :prepare_target},
                 {Profiles, :build},
                 {Headless, :start_link},
                 {Headless, :execute},
                 {Segment, :prepare_effect},
                 {Segment, :consume_effect},
                 {Continuations, :commit},
                 {RuntimeStore, :put_fact}
               ]

             {:adapter_call, _, _, _, _} ->
               true

             _ ->
               false
           end) == []
  end

  defp open_fixture(root, files) do
    assert File.regular?(@node)
    assert :ok = SessionStore.ensure_started()
    session_id = Ecto.UUID.generate()
    run_id = Ecto.UUID.generate()
    caller = "synapsis:" <> session_id
    all_names = @names ++ [@caller_tool]
    assert {:ok, store} = Store.new(1)

    assert {:ok, agent} =
             Synapsis.AgentConfigs.create(%{
               name: "segment-workflow-#{session_id}",
               enabled: true,
               tools: @names,
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
    assert {:ok, native} = HostCodeMode.bundles(%{session_binding: binding}, ceiling, @names)
    adapter = start_supervised!({AdapterHost, self()})

    fetch = fn invocation, catalog, digest ->
      GenServer.call(adapter, {:filesystem_target_fetch, invocation, catalog, digest}, 5_000)
    end

    profiles_context = %{
      session: %{id: session_id, config: %{"subagents" => false}},
      agent: %{id: agent.id, name: agent.name, tools: @names, tool_contract_version: 1},
      project_path: files,
      tool_filesystem: %{
        path_environment: %{
          cwd: files,
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

    registration = SessionAdapter.workflow_effect_registration(adapter, run_id, 1)

    descriptor = %{
      tool_name: @caller_tool,
      tool_revision: 1,
      backend: CallerBackend,
      backend_context: %{
        observer: self(),
        adapter: adapter,
        pipeline: @pipeline,
        steps: [
          %{
            target: %{
              tool_name: "synapsis::read",
              tool_revision: 1,
              arguments: %{"path" => "first.txt"}
            },
            raw: @first
          },
          %{
            target: %{
              tool_name: "synapsis::read",
              tool_revision: 1,
              arguments: %{"path" => "second.txt"}
            },
            raw: @second
          }
        ],
        workflow_effect_registration: registration,
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
      work: 12,
      run_timeout: 90_000,
      effect_timeout: 70_000,
      commit_timeout: 5_000,
      cleanup_timeout: 5_000
    ]

    assert {:ok, parent} = Headless.start_link(options)
    on_exit(fn -> if Process.alive?(parent), do: GenServer.stop(parent, :normal, 5_000) end)

    %{
      parent: parent,
      session: session,
      binding: binding,
      identity: identity,
      adapter: adapter,
      store: store
    }
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

  defp returned(events, index, pid, mfa) do
    assert {{:trace, ^pid, :return_from, ^mfa, value}, return_index} =
             events
             |> Enum.with_index()
             |> Enum.drop(index + 1)
             |> Enum.find(fn
               {{:trace, ^pid, :return_from, ^mfa, _}, _} -> true
               _ -> false
             end)

    {return_index, value}
  end

  defp cleanup_journal(session_id, namespace) do
    for prefix <- [
          "coord/runtime/facts/" <> key_segment(session_id) <> "/",
          "coord/runtime/runs/" <> key_segment(namespace) <> "/",
          "coord/workflow_continuations/" <> session_id <> "/"
        ] do
      {:ok, pairs} = Concord.Turso.prefix_scan(prefix, timeout: 5_000)
      for {key, _} <- pairs, do: Concord.Turso.delete(key, timeout: 5_000)
    end
  end

  defp key_segment(value), do: value |> to_string() |> Base.url_encode64(padding: false)
  defp now, do: System.monotonic_time(:millisecond)
end
