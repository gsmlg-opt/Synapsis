defmodule Synapsis.Agent.Tools.Workflows.SegmentStateDriverFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex.{CodeMode, Headless, ResourceRegistry, Session}
  alias Synapsis.Agent.Runtime.{SessionAdapter, Store}
  alias Synapsis.Agent.Tools.{Catalog, Policy, Profiles}
  alias Synapsis.Agent.Tools.CodeMode, as: HostCodeMode
  alias Synapsis.Agent.Tools.Workflows.{Journal, Segment}
  alias Synapsis.Filesystem.{Local, StateFile}
  alias Synapsis.Runtime.Store, as: RuntimeStore
  alias Synapsis.Session.Store, as: SessionStore
  alias Synapsis.Workflow.{Continuations, Live, Machine, State}
  alias Synapsis.Workflow.Provenance.Owner
  alias Synapsis.Workflow.Schema.PortSession
  alias Synapsis.Workflow.Segment, as: CoreSegment

  @moduletag :tmp_dir
  @moduletag timeout: 180_000
  @root Path.expand("../../../../../../..", __DIR__)
  @node "/nix/store/q3ydkdhaj4y6k9pbpnriv5miqdgs1gsf-nodejs-24.21.0/bin/node"
  @caller_tool "fixture_segment_state_driver"
  @names ~w(exec wait synapsis::read synapsis::write synapsis::edit synapsis::ls)
  @root_source "// @exec: {\"yield_time_ms\": 10000}\nreturn (await tools.fixture_segment_state_driver({})).value;\n"
  @trace_targets [
    {Segment, :run_state, 3},
    {Segment, :resume_state, 5},
    {Segment, :decode_state_token, 1},
    {Journal, :run_state_segment, 5},
    {Journal, :reopen_segment, 5},
    {Profiles, :build, 4},
    {Headless, :start_link, 1},
    {Headless, :execute, 3},
    {ResourceRegistry, :register, 5},
    {ResourceRegistry, :fetch, 3},
    {ResourceRegistry, :release, 3},
    {ResourceRegistry, :cleanup_status, 3},
    {CodeMode.Worker, :os_identity, 1},
    {RuntimeStore, :put_fact, 4},
    {RuntimeStore, :get_fact, 3},
    {Continuations, :create, 4},
    {Continuations, :commit, 5},
    {CoreSegment, :new, 2},
    {CoreSegment, :advance_observed, 1},
    {CoreSegment, :advance_observed, 2},
    {CoreSegment, :resume_observed, 2},
    {CoreSegment, :consume_operation_observed, 3},
    {Machine, :advance_observed, 2},
    {Machine, :resume_observed, 2},
    {State, :decode, 2},
    {State, :diff, 3},
    {Local, :start_state_operation, 3},
    {Local, :run_state_operation, 2},
    {Local, :close_state_operation, 1},
    {StateFile, :run, 2},
    {Live, :open, 3},
    {Live, :publish_observed, 5},
    {Live, :retire, 2},
    {Owner, :open, 4},
    {Owner, :publish, 4},
    {Owner, :retire, 2},
    {Owner, :handle_call, 3},
    {PortSession, :start_link, 1},
    {PortSession, :fulfill, 4},
    {PortSession, :close, 1}
  ]

  # Only the internal fixture caller is installed. This wrapper starts with an
  # ordinary issued Profiles snapshot and an empty preparation ledger, and
  # delegates the actual production registration/preparation handlers unchanged.
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
    alias Backplane.AgentRuntime.Codex.Session
    alias Synapsis.Agent.Tools.Workflows.Segment

    def execute(operation) do
      context = operation.backend_context
      :erlang.trace(self(), true, [:call, :procs, :set_on_spawn, {:tracer, context.observer}])

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
          :project_root,
          :ceiling,
          :store,
          :session_id,
          :caller,
          :workflow_effect_registration,
          :schema_runtime
        ])
        |> Map.put(:profiles_snapshot, snapshot)
        |> Map.put(:operation, operation)

      before_parent = parent_state(operation)

      result =
        case context.action do
          {:run, pipeline} ->
            Segment.run_state(pipeline, supplied, context.state_options)

          {:resume, token, raw} ->
            with {:ok, %{workflow_id: id, revision: revision}} <-
                   Segment.decode_state_token(token) do
              Segment.resume_state(id, revision, raw, supplied, %{
                provenance_owner: context.state_options.provenance_owner
              })
            end
        end

      after_parent = parent_state(operation)
      barrier = :erlang.trace_delivered(:all)

      receive do
        {:trace_delivered, :all, ^barrier} -> :ok
      after
        5_000 -> raise "ordinary state driver trace did not drain"
      end

      send(
        context.observer,
        {:driver_outcome, self(), operation, result, before_parent, after_parent}
      )

      case result do
        {:ok, outcome} -> {:ok, %{value: outcome.envelope, is_error: false}}
        error -> error
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

  test "same-stage ask resumes in a fresh admitted root without replaying consumed writes", %{
    tmp_dir: root
  } do
    checkpoint_scenario(root, "same_stage")
  end

  test "next-stage ask resumes in a fresh admitted root without replaying consumed writes", %{
    tmp_dir: root
  } do
    checkpoint_scenario(root, "next_stage")
  end

  test "admitted get set diff and alias get preserve exact source keys and real file evidence", %{
    tmp_dir: root
  } do
    fixture = setup_fixture(root)
    File.write!(Path.join(fixture.state_dir, "i.json"), "{\"b\":2,\"a\":1}\n")
    File.write!(Path.join(fixture.state_dir, "comparison.json"), "0\n")
    pipeline = "state.get 'İ' | state.set 'K' | diff.last --key comparison | state.get k"
    native = open_state_root(fixture, fixture.store, {:run, pipeline})
    {outcome, events, caller, operation} = exercise(native)
    assert outcome.envelope["status"] == "ok"
    assert outcome.envelope["output"] == [%{"b" => 2, "a" => 1}]
    operations = outcome.record.snapshot["journal"]["operations"]

    assert Enum.map(operations, & &1["request"]["semantic"]["key"]) == [
             "İ",
             "K",
             "comparison",
             "k"
           ]

    assert Enum.map(operations, & &1["request"]["target"]["lexical_path"]) ==
             ["state/i.json", "state/k.json", "state/comparison.json", "state/k.json"]

    assert File.read!(Path.join(fixture.state_dir, "k.json")) == "{\n  \"b\": 2,\n  \"a\": 1\n}\n"

    assert File.read!(Path.join(fixture.state_dir, "comparison.json")) ==
             File.read!(Path.join(fixture.state_dir, "k.json"))

    assert File.read!(Path.join(fixture.state_dir, "i.json")) == "{\"b\":2,\"a\":1}\n"
    assert_operation_protocol(native, outcome, events, operation, 0)
    assert_normal_retirement(native, outcome, events, caller)
    assert_observed_publications(events)
    assert_readonly_reopen(native, outcome, events)
    close_root(native, events)
  end

  test "unchanged diff still performs a real unconditional file publication", %{tmp_dir: root} do
    fixture = setup_fixture(root)
    File.write!(Path.join(fixture.state_dir, "seed.json"), "{\"a\":1}\n")
    # Equal JSON with a distinct source spelling proves diff did publish its
    # pretty request bytes rather than silently retaining the previous file.
    File.write!(Path.join(fixture.state_dir, "comparison.json"), "{\"a\":1}\n")

    native =
      open_state_root(
        fixture,
        fixture.store,
        {:run, "state.get seed | diff.last --key comparison"}
      )

    {outcome, events, caller, operation} = exercise(native)

    assert outcome.envelope["output"] == [
             %{
               "kind" => "diff.last",
               "key" => "comparison",
               "changed" => false,
               "before" => %{"a" => 1},
               "after" => %{"a" => 1}
             }
           ]

    assert File.read!(Path.join(fixture.state_dir, "comparison.json")) == "{\n  \"a\": 1\n}\n"
    steps = assert_operation_protocol(native, outcome, events, operation, 0)
    diff = List.last(steps)
    assert diff.fact.result.ack["changed"] == false
    assert diff.fact.result.local.publication == :published
    assert diff.fact.result.write_bytes == "{\n  \"a\": 1\n}\n"
    assert_normal_retirement(native, outcome, events, caller)
    assert_observed_publications(events)
    close_root(native, events)
  end

  defp checkpoint_scenario(root, mode) do
    fixture = setup_fixture(root)
    File.write!(Path.join(fixture.state_dir, "initial.json"), "\"ready\"\n")
    File.write!(Path.join(fixture.state_dir, "baseline.json"), "\"old\"\n")
    flag = if mode == "next_stage", do: " --emit", else: ""

    pipeline =
      "state.get initial | state.set before | ask --prompt Review --schema '{\"type\":\"string\"}' --subject-from-stdin" <>
        flag <> " | state.set reply | diff.last baseline"

    first = open_state_root(fixture, fixture.store, {:run, pipeline})
    {initial, events, caller, operation} = exercise(first)
    assert initial.record.revision == 8
    assert initial.record.snapshot["revision"] == 8
    assert initial.record.snapshot["version"] == 3
    assert initial.record.snapshot["consumed_operations"] == 2

    assert initial.record.snapshot["source"] == %{
             "kind" => "inline",
             "pipeline" => pipeline,
             "state_scope" => fixture.scope
           }

    machine = initial.record.snapshot["machine"]
    assert machine["phase"] == "checkpoint"
    assert machine["checkpoint"]["mode"] == mode
    assert machine["checkpoint"]["stage_index"] == 2
    assert initial.envelope["status"] == "needs_input"
    assert initial.envelope["requiresInput"]["prompt"] == "Review"
    assert initial.envelope["requiresInput"]["subject"] == %{"text" => "ready"}
    token = initial.envelope["requiresInput"]["resumeToken"]
    assert "workflow-segment.v3." <> encoded = token

    assert encoded |> Base.url_decode64!(padding: false) |> Jason.decode!() ==
             %{"workflowId" => initial.record.id, "revision" => 8}

    first_steps = assert_operation_protocol(first, initial, events, operation, 0)

    assert Enum.map(first_steps, & &1.fact.request["semantic"]["kind"]) == [
             "state_get",
             "state_set"
           ]

    assert commit_revisions(events) == Enum.to_list(2..8)
    assert File.read!(Path.join(fixture.state_dir, "before.json")) == "\"ready\"\n"
    assert File.read!(Path.join(fixture.state_dir, "baseline.json")) == "\"old\"\n"
    assert_normal_retirement(first, initial, events, caller)
    assert_observed_publications(events)
    assert_readonly_reopen(first, initial, events)
    close_root(first, events)

    second =
      open_state_root(
        fixture,
        %{fixture.store | incarnation: 2},
        {:resume, token, ~S("accepted")}
      )

    assert second.identity.run_id != first.identity.run_id
    assert second.identity.incarnation == 2
    assert second.parent != first.parent
    assert second.session != first.session
    assert second.adapter != first.adapter
    assert second.binding.resource_registry != first.binding.resource_registry
    {resumed, resumed_events, fresh_caller, fresh_operation} = exercise(second)
    assert fresh_caller != caller
    assert resumed.record.id === initial.record.id
    assert resumed.record.session_id === initial.record.session_id
    assert resumed.record.agent_id === initial.record.agent_id
    assert resumed.record.revision == 16
    assert resumed.record.snapshot["revision"] == 16
    assert resumed.record.snapshot["source"] === initial.record.snapshot["source"]
    assert resumed.record.snapshot["consumed_operations"] == 4

    assert Enum.take(resumed.record.snapshot["journal"]["operations"], 2) ===
             initial.record.snapshot["journal"]["operations"]

    assert resumed.record.snapshot["machine"]["phase"] == "completed"
    assert resumed.record.snapshot["machine"]["segment"] == 1

    assert resumed.envelope == %{
             "ok" => true,
             "status" => "ok",
             "requiresApproval" => nil,
             "output" => [
               %{
                 "kind" => "diff.last",
                 "key" => "baseline",
                 "changed" => true,
                 "before" => "old",
                 "after" => "accepted"
               }
             ]
           }

    assert File.read!(Path.join(fixture.state_dir, "reply.json")) == "\"accepted\"\n"
    assert File.read!(Path.join(fixture.state_dir, "baseline.json")) == "\"accepted\"\n"
    assert File.read!(Path.join(fixture.state_dir, "before.json")) == "\"ready\"\n"
    assert commit_revisions(resumed_events) == Enum.to_list(9..16)
    second_steps = assert_operation_protocol(second, resumed, resumed_events, fresh_operation, 2)

    assert Enum.map(second_steps, & &1.fact.request["semantic"]["kind"]) == [
             "state_set",
             "state_diff"
           ]

    assert Enum.all?(second_steps, &(&1.fact.request["correlation"]["segment"] == 1))
    assert_resume_claim(initial, resumed_events, first_steps)
    assert_normal_retirement(second, resumed, resumed_events, fresh_caller)
    assert_observed_publications(resumed_events)
    assert resumed.retirement.helper.os_pid != initial.retirement.helper.os_pid
    assert_readonly_reopen(second, resumed, resumed_events)

    for step <- first_steps do
      assert RuntimeStore.get_fact(
               first.identity.session_id,
               :workflow_state_receipt,
               step.reference["fact_id"]
             ) === {:ok, step.fact}
    end

    close_root(second, resumed_events)
  end

  defp setup_fixture(root) do
    install_observation()
    assert File.regular?(@node)
    assert :ok = SessionStore.ensure_started()
    files = Path.join(root, "files")
    state_dir = Path.join(files, "state")
    File.mkdir_p!(state_dir)
    session_id = Ecto.UUID.generate()
    assert {:ok, store} = Store.new(1)

    assert {:ok, agent} =
             Synapsis.AgentConfigs.create(%{
               name: "segment-state-driver-#{session_id}",
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
    provenance_owner = start_supervised!({Owner, name: nil})
    :erlang.trace(provenance_owner, true, [:call, :procs, :set_on_spawn, {:tracer, self()}])

    scope = %{
      "kind" => "trusted_internal",
      "project_root" => files,
      "state_dir" => "./state",
      "process_cwd" => files
    }

    on_exit(fn ->
      SessionStore.delete_session(session_id)
      Synapsis.AgentConfigs.delete(agent)
      cleanup(session_id, store.namespace)
    end)

    %{
      root: root,
      files: files,
      state_dir: state_dir,
      session_id: session_id,
      store: store,
      agent: agent,
      scope: scope,
      provenance_owner: provenance_owner
    }
  end

  defp open_state_root(fixture, store, action),
    do:
      open_root(fixture.root, fixture.files, fixture.session_id, fixture.agent, store, action, %{
        state_scope: fixture.scope,
        provenance_owner: fixture.provenance_owner
      })

  defp assert_operation_protocol(fixture, outcome, events, operation, prefix) do
    entries = outcome.record.snapshot["journal"]["operations"]
    assert outcome.record.snapshot["consumed_operations"] == length(entries)

    assert {:ok, %{consumed_operations: cursor}} =
             CoreSegment.inspect_snapshot(outcome.record.snapshot)

    assert cursor == length(entries)
    assert outcome.record.snapshot === json_roundtrip(outcome.record.snapshot)
    assert_data_only(outcome.record.snapshot)

    assert Continuations.load(fixture.identity.session_id, outcome.record.id) ===
             {:ok, outcome.record}

    new_entries = Enum.drop(entries, prefix)
    runs = calls(events, Local, :run_state_operation)
    assert length(runs) == length(new_entries)
    assert length(calls(events, Journal, :run_state_segment)) == length(new_entries)
    assert length(calls(events, CoreSegment, :consume_operation_observed)) == length(new_entries)

    assert length(
             for {_, _, [_, :workflow_state_receipt, _, _]} <-
                   calls(events, RuntimeStore, :put_fact),
                 do: :fact
           ) == length(new_entries)

    for {entry, ordinal} <- Enum.with_index(new_entries, prefix) do
      request = entry["request"]
      semantic = request["semantic"]
      id = semantic["id"]
      pending_revision = entry["pending_revision"]
      reference = entry["receipt"]
      assert entry["type"] == "state_operation"
      assert entry["state"] == "settled"
      assert entry["settled_revision"] == pending_revision + 1
      assert request["scope"] === outcome.record.snapshot["source"]["state_scope"]

      assert request["correlation"] == %{
               "workflow_id" => outcome.record.id,
               "request_id" => id,
               "segment" => if(prefix == 0, do: 0, else: 1)
             }

      assert request["target"]["absolute_path"] ==
               Path.join(fixture.files, request["target"]["relative_path"])

      assert entry["origin"] == %{
               "namespace" => fixture.store.namespace,
               "store_incarnation" => fixture.store.incarnation,
               "parent_run_id" => operation.run_id,
               "parent_incarnation" => operation.incarnation,
               "parent_invocation_id" => operation.invocation_id,
               "caller" => operation.caller,
               "resource_owner_id" => fixture.binding.owner_id,
               "resource_incarnation" => fixture.binding.incarnation
             }

      assert reference == %{
               "kind" => "workflow_state_receipt",
               "version" => 1,
               "fact_id" => outcome.record.id <> ":state:" <> Integer.to_string(pending_revision),
               "namespace" => fixture.store.namespace,
               "incarnation" => fixture.store.incarnation
             }

      {pending_call, pending_pid, [_, _, _, pending, _]} =
        one_call(events, Continuations, :commit, fn [_, _, revision, _, _] ->
          revision == pending_revision - 1
        end)

      assert pending["machine"]["pending_request"] === semantic
      assert pending["consumed_operations"] == ordinal
      assert pending["revision"] == pending_revision
      assert List.last(pending["journal"]["operations"])["state"] == "pending"

      {pending_ack, {:ok, pending_record}} =
        returned(events, pending_call, pending_pid, {Continuations, :commit, 5})

      assert pending_record.snapshot === pending

      {run_call, run_pid, [ticket, local_request]} = Enum.at(runs, ordinal - prefix)
      assert pending_ack < run_call

      {run_ack, {:ok, actual_local}} =
        returned(events, run_call, run_pid, {Local, :run_state_operation, 2})

      guardian = elem(ticket, 2)

      {register_call, register_pid, [registry, owner_id, :workflow_state_io, ^guardian, options]} =
        one_call(events, ResourceRegistry, :register, fn [_, _, kind, child, _] ->
          kind == :workflow_state_io and child == guardian
        end)

      assert options[:owner_pid] == run_pid
      assert options[:incarnation] == fixture.binding.incarnation
      assert is_function(options[:cleanup], 0)
      assert registry == fixture.binding.resource_registry
      assert owner_id == fixture.binding.owner_id

      {register_ack, {:ok, handle}} =
        returned(events, register_call, register_pid, {ResourceRegistry, :register, 5})

      assert pending_ack < register_call
      assert register_ack < run_call

      {release_call, release_pid, [^registry, ^handle, ^owner_id]} =
        one_call(events, ResourceRegistry, :release, fn [r, h, _] ->
          r == registry and h == handle
        end)

      {release_ack, {:ok, :ok}} =
        returned(events, release_call, release_pid, {ResourceRegistry, :release, 3})

      assert run_ack < release_call

      [{close_call, close_pid, [^ticket]}] =
        Enum.filter(calls(events, Local, :close_state_operation), fn {_, _, [t]} ->
          t == ticket
        end)

      {close_ack, :ok} =
        returned(events, close_call, close_pid, {Local, :close_state_operation, 1})

      assert release_call < close_call
      assert close_ack < release_ack
      assert Enum.any?(events, &match?({:trace, ^guardian, :exit, :normal}, &1))
      refute Process.alive?(guardian)

      assert {:ok, %{status: :confirmed}} =
               ResourceRegistry.cleanup_status(registry, handle, owner_id)

      {fact_call, fact_pid, [session_id, :workflow_state_receipt, fact_id, fact]} =
        one_call(events, RuntimeStore, :put_fact, fn [_, kind, name, _] ->
          kind == :workflow_state_receipt and name == reference["fact_id"]
        end)

      assert fact_id == reference["fact_id"]
      assert session_id == fixture.identity.session_id
      assert release_ack < fact_call

      assert Enum.sort(Map.keys(fact)) ==
               ~w(agent_id origin pending_revision request result retirement version workflow_id)a

      assert fact.version == 1
      assert fact.workflow_id == outcome.record.id
      assert fact.agent_id == outcome.record.agent_id
      assert fact.pending_revision == pending_revision
      assert fact.request === request
      assert fact.origin === entry["origin"]
      assert fact.result.local === Map.drop(actual_local, [:value])
      assert fact.retirement == %{resource_handle: handle, release: :confirmed, guardian: :normal}
      assert_data_only(fact)
      assert RuntimeStore.get_fact(session_id, :workflow_state_receipt, fact_id) === {:ok, fact}
      {fact_ack, :ok} = returned(events, fact_call, fact_pid, {RuntimeStore, :put_fact, 4})

      {settled_call, settled_pid, [_, _, _, settled, _]} =
        one_call(events, Continuations, :commit, fn [_, _, revision, _, _] ->
          revision == pending_revision
        end)

      {settled_ack, {:ok, settled_record}} =
        returned(events, settled_call, settled_pid, {Continuations, :commit, 5})

      assert fact_ack < settled_call
      assert settled["machine"] === pending["machine"]
      assert settled["consumed_operations"] == ordinal
      assert settled["revision"] == pending_revision + 1
      assert settled_record.snapshot === settled
      assert List.last(settled["journal"]["operations"]) === entry

      {consumed_call, consumed_pid, [_, _, _, consumed, _]} =
        one_call(events, Continuations, :commit, fn [_, _, revision, _, _] ->
          revision == pending_revision + 1
        end)

      {consumed_ack, {:ok, consumed_record}} =
        returned(events, consumed_call, consumed_pid, {Continuations, :commit, 5})

      assert settled_ack < consumed_call
      assert consumed["revision"] == pending_revision + 2
      assert consumed["consumed_operations"] == ordinal + 1
      assert consumed["journal"] === settled["journal"]
      assert consumed["machine"]["pending_request"] == nil
      assert consumed_record.snapshot === consumed

      {consume_call, consume_pid, [prospective, next_revision, ack]} =
        one_call(events, CoreSegment, :consume_operation_observed, fn [_, _, a] ->
          a["id"] == id
        end)

      {consume_ack, {{:ok, candidate}, observations}} =
        returned(events, consume_call, consume_pid, {CoreSegment, :consume_operation_observed, 3})

      assert prospective === settled
      assert next_revision == pending_revision + 2
      assert candidate === consumed
      assert consume_ack < fact_call
      assert ack === fact.result.ack
      assert ack["id"] == id
      assert ack["kind"] == semantic["kind"]
      assert ack["result"] == "ok"
      assert_helper_evidence(events, fact, semantic, pending["machine"])

      assert_state_semantics(
        events,
        local_request,
        run_call,
        run_ack,
        consume_call,
        consume_ack,
        consume_pid,
        semantic,
        ack,
        observations,
        fact
      )

      for {index, _, [state, _]} <- calls(events, CoreSegment, :advance_observed),
          state["consumed_operations"] == ordinal + 1 do
        assert consumed_ack < index
      end

      %{fact: fact, reference: reference, consumed: consumed_record, consumed_ack: consumed_ack}
    end
  end

  defp assert_helper_evidence(events, fact, semantic, machine) do
    pairs = fact.result.helper_receipts

    assert Enum.map(pairs, & &1.request["kind"]) ==
             if(semantic["kind"] == "state_set",
               do: ["state_key_path"],
               else: ["state_key_path", "decode_state_text"]
             )

    [key_pair | _] = pairs

    assert key_pair.request == %{
             "id" => semantic["id"],
             "kind" => "state_key_path",
             "key" => semantic["key"],
             "state_dir" => fact.request["scope"]["state_dir"]
           }

    assert Enum.sort(Map.keys(key_pair.receipt)) ==
             ~w(cacheEntries id lexical_path outcome result type)

    assert key_pair.receipt["outcome"] == "state_path"
    assert key_pair.receipt["lexical_path"] == fact.request["target"]["lexical_path"]

    for pair <- pairs do
      {index, pid, [_, request, heap, _]} =
        one_call(events, PortSession, :fulfill, fn [_, request, _, _] ->
          request === pair.request
        end)

      {_, {:ok, receipt}} = returned(events, index, pid, {PortSession, :fulfill, 4})
      assert request === pair.request
      assert receipt === pair.receipt
      assert heap === machine["heap"]
      assert receipt["id"] == semantic["id"]
      assert receipt["type"] == "result"
      assert receipt["result"] == "ok"
    end

    case semantic["kind"] do
      "state_set" ->
        assert fact.result.capture == :not_captured
        assert fact.result.local.before == :not_captured
        assert fact.result.write_bytes === semantic["text"]

      kind when kind in ["state_get", "state_diff"] ->
        [_, decode] = pairs
        capture = fact.result.capture
        assert capture.exists
        assert capture.bytes === fact.result.local.before.bytes
        assert capture.exists === fact.result.local.before.exists
        assert capture.text === capture.bytes

        assert decode.request == %{
                 "id" => semantic["id"],
                 "kind" => "decode_state_text",
                 "bytes_base64" => Base.encode64(capture.bytes)
               }

        assert Enum.sort(Map.keys(decode.receipt)) ==
                 ~w(cacheEntries id outcome result type value)

        assert decode.receipt["outcome"] == "decoded"
        assert decode.receipt["value"] == %{"type" => "string", "value" => capture.text}

        assert fact.result.write_bytes ===
                 if(kind == "state_get", do: nil, else: semantic["text"])
    end
  end

  defp assert_state_semantics(
         events,
         local_request,
         run_call,
         run_ack,
         consume_call,
         consume_ack,
         consume_pid,
         semantic,
         ack,
         observations,
         fact
       ) do
    {publish_call, publish_pid, [_, before, {transition, ^observations}, context, _]} =
      one_call(events, Live, :publish_observed, fn [_, before, {_, obs}, context, _] ->
        before["pending_request"] === semantic and obs === observations and
          is_map(context) and context[:request_id] == semantic["id"]
      end)

    {publish_ack, {:ok, ^transition, _}} =
      returned(events, publish_call, publish_pid, {Live, :publish_observed, 5})

    assert before["pending_request"] === semantic

    assert context == %{
             request_id: semantic["id"],
             lexical_path: fact.request["target"]["lexical_path"]
           }

    assert consume_ack < publish_call
    assert publish_pid == consume_pid
    assert fact.result.local.cleanup_confirmed

    case semantic["kind"] do
      "state_get" ->
        assert {:read_locked, callback} = local_request
        assert is_function(callback, 1)
        assert ack["text"] === fact.result.capture.text
        assert [{:state_read, id, _, text}] = observations
        assert id == semantic["id"]
        assert text === fact.result.capture.text
        assert run_call < consume_call
        assert publish_ack < run_ack
        assert fact.result.local.publication == :not_applicable
        assert fact.result.local.file_sync == :not_applicable

        assert Enum.any?(calls(events, State, :decode), fn {index, pid, [text, _]} ->
                 pid == consume_pid and text === ack["text"] and consume_call < index and
                   index < consume_ack
               end)

        exit_index = Enum.find_index(events, &match?({:trace, ^consume_pid, :exit, :normal}, &1))
        assert is_integer(exit_index)
        assert publish_ack < exit_index
        assert exit_index < run_ack

        [{state_file_call, state_file_pid, _}] =
          Enum.filter(
            calls(events, StateFile, :run),
            fn {index, _, [_, req]} ->
              run_call < index and index < run_ack and req === local_request
            end
          )

        {lock_released, _} =
          returned(events, state_file_call, state_file_pid, {StateFile, :run, 2})

        assert exit_index < lock_released
        assert publish_ack < lock_released

      "state_set" ->
        assert local_request === {:write_always, semantic["text"]}

        assert observations === [
                 {:state_written, semantic["id"], semantic["value"], semantic["text"]}
               ]

        assert run_ack < consume_call
        assert fact.result.local.publication == :published
        assert fact.result.local.file_sync == :confirmed

      "state_diff" ->
        assert {:transition_locked, callback} = local_request
        assert is_function(callback, 1)
        assert observations == []
        assert ack["before_text"] === fact.result.capture.text
        assert is_boolean(ack["changed"])
        assert run_ack < consume_call
        assert fact.result.local.publication == :published
        assert fact.result.local.file_sync == :confirmed
    end
  end

  defp assert_observed_publications(events) do
    machine_results =
      (returns(events, Machine, :advance_observed, 2) ++
         returns(events, Machine, :resume_observed, 2))
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(&elem(&1, 2))

    published_results =
      for {_, _, [_, _, observed, _, _]} <- calls(events, Live, :publish_observed), do: observed

    assert machine_results != []
    assert published_results === machine_results
    assert length(calls(events, Owner, :publish)) == length(published_results)

    for {index, pid, [binding, before, {transition, _}, _, _]} <-
          calls(events, Live, :publish_observed) do
      {ack, {:ok, ^transition, current}} =
        returned(events, index, pid, {Live, :publish_observed, 5})

      assert current.lease === binding.lease
      assert current.graph === binding.graph
      assert current.seq == binding.seq + 1

      [{owner_call, owner_pid, [^binding, delta, _, _]}] =
        Enum.filter(
          calls(events, Owner, :publish),
          fn {i, p, [b, _, _, _]} -> index < i and i < ack and p == pid and b === binding end
        )

      {_, {:ok, ^current}} = returned(events, owner_call, owner_pid, {Owner, :publish, 4})
      next = elem(transition, tuple_size(transition) - 1)
      assert delta === Synapsis.Workflow.Value.heap_delta(before["heap"], next["heap"])
    end
  end

  defp assert_normal_retirement(fixture, outcome, events, caller) do
    retirement = outcome.retirement
    assert retirement.release == :confirmed
    assert retirement.broker == :terminated
    assert retirement.resource_handle.kind == :workflow_schema
    assert retirement.helper.cleanup_confirmed
    assert retirement.helper.exit_status == 0
    refute File.exists?("/proc/#{retirement.helper.os_pid}")

    {register_call, register_pid, [registry, _, :workflow_schema, broker, options]} =
      one_call(events, ResourceRegistry, :register, fn [_, _, kind, _, _] ->
        kind == :workflow_schema
      end)

    {register_ack, {:ok, handle}} =
      returned(events, register_call, register_pid, {ResourceRegistry, :register, 5})

    assert handle === retirement.resource_handle
    assert options[:owner_pid] == caller
    assert registry === fixture.binding.resource_registry

    for {index, _, [^broker, _, _, _]} <- calls(events, PortSession, :fulfill),
        do: assert(register_ack < index)

    [{_, _, [helper_options]}] = calls(events, PortSession, :start_link)
    assert helper_options[:node_executable] == @node

    assert helper_options[:helper_path] ==
             Path.join(@root, "packages/tool-host/src/workflow/schema-stdio.mjs")

    [{close_call, close_pid, [^broker]}] = calls(events, PortSession, :close)
    {_, {:ok, helper}} = returned(events, close_call, close_pid, {PortSession, :close, 1})
    assert helper === retirement.helper
    refute Process.alive?(broker)
    [{retire_call, retire_pid, [binding, _]}] = calls(events, Live, :retire)
    {_, :ok} = returned(events, retire_call, retire_pid, {Live, :retire, 2})
    assert :sys.get_state(binding.server).leases == %{}
    assert_data_only(outcome.record.snapshot)
    assert_code_worker_retired(events, fixture.binding.resource_registry)
  end

  defp assert_resume_claim(retained, events, previous_steps) do
    {reopen_call, reopen_pid, [session_id, agent_id, id, revision, _]} =
      one_call(events, Journal, :reopen_segment, fn _ -> true end)

    assert {session_id, agent_id, id, revision} ===
             {retained.record.session_id, retained.record.agent_id, retained.record.id,
              retained.record.revision}

    {reopen_ack, {:ok, reopened}} =
      returned(events, reopen_call, reopen_pid, {Journal, :reopen_segment, 5})

    assert reopened.record === retained.record
    assert length(reopened.entries) == length(previous_steps)

    for step <- previous_steps do
      {read, read_pid, _} =
        one_call(events, RuntimeStore, :get_fact, fn [_, kind, fact_id] ->
          kind == :workflow_state_receipt and fact_id == step.reference["fact_id"]
        end)

      {read_ack, {:ok, fact}} = returned(events, read, read_pid, {RuntimeStore, :get_fact, 3})
      assert fact === step.fact
      assert reopen_call < read
      assert read_ack < reopen_ack
    end

    assert Enum.all?(calls(events, Local, :run_state_operation), fn {index, _, _} ->
             reopen_ack < index
           end)

    assert Enum.all?(calls(events, PortSession, :fulfill), fn {index, _, _} ->
             reopen_ack < index
           end)

    {resume_call, _, [snapshot, response]} =
      one_call(events, CoreSegment, :resume_observed, fn _ -> true end)

    assert snapshot === retained.record.snapshot
    assert response == ~S("accepted")
    assert reopen_ack < resume_call
    [{open_call, open_pid, [_, loaded_machine, _]}] = calls(events, Live, :open)
    {open_ack, {:ok, binding}} = returned(events, open_call, open_pid, {Live, :open, 3})
    assert loaded_machine === retained.record.snapshot["machine"]
    assert open_ack < resume_call

    {_, _, [_message, _from, _state]} =
      one_call(events, Owner, :handle_call, fn [message, _, _] ->
        match?({:open, _, _}, message)
      end)

    [{_, _, {:reply, {:ok, opened}, opened_state}}] =
      Enum.filter(returns(events, Owner, :handle_call, 3), fn
        {_, _, {:reply, {:ok, %Owner.Binding{} = current}, _}} ->
          current.lease === binding.lease and current.seq == 0

        _ ->
          false
      end)

    assert opened_state.graphs[opened.graph].marks == %{}

    {claim_call, claim_pid, [_, _, _, claim, _]} =
      one_call(events, Continuations, :commit, fn [_, _, expected, _, _] ->
        expected == retained.record.revision
      end)

    {claim_ack, {:ok, claimed}} =
      returned(events, claim_call, claim_pid, {Continuations, :commit, 5})

    assert claimed.snapshot === claim
    assert claim["source"] === retained.record.snapshot["source"]
    assert claim["journal"] === retained.record.snapshot["journal"]
    assert claim["consumed_operations"] == retained.record.snapshot["consumed_operations"]
    assert claim["machine"]["next_request"] >= retained.record.snapshot["machine"]["next_request"]
    assert claim["machine"]["phase"] == "construct"
    assert claim["machine"]["frames"] == []
    assert claim["machine"]["stack"] == [%{"op" => "construct"}]
    for {index, _, _} <- calls(events, Local, :run_state_operation), do: assert(claim_ack < index)

    for {index, _, [_, _, actions, _]} <- calls(events, Owner, :publish), index < claim_ack do
      assert Enum.all?(actions, &(elem(&1, 0) not in [:remember, :carry_remembered]))
    end

    constructors =
      for {index, _, [state, nil]} <- calls(events, CoreSegment, :advance_observed),
          state["machine"]["phase"] == "construct",
          state["machine"]["stack"] == [%{"op" => "construct"}],
          do: index

    assert constructors != []
    assert Enum.all?(constructors, &(claim_ack < &1))

    refute Enum.any?(calls(events, RuntimeStore, :put_fact), fn {_, _, [_, _, id, _]} ->
             Enum.any?(previous_steps, &(&1.reference["fact_id"] == id))
           end)
  end

  defp assert_readonly_reopen(fixture, outcome, _old_events) do
    parent = self()

    reader =
      spawn(fn ->
        receive do
          :read ->
            result =
              Journal.reopen_segment(
                fixture.identity.session_id,
                outcome.record.agent_id,
                outcome.record.id,
                outcome.record.revision,
                deadline: System.monotonic_time(:millisecond) + 10_000
              )

            barrier = :erlang.trace_delivered(self())

            receive do
              {:trace_delivered, _, ^barrier} -> :ok
            after
              5_000 -> raise "read-only reopen trace did not drain"
            end

            send(parent, {:readonly_reopened, self(), result})
        end
      end)

    :erlang.trace(reader, true, [:call, :procs, :set_on_spawn, {:tracer, self()}])
    send(reader, :read)
    assert_receive {:readonly_reopened, ^reader, {:ok, reopened}}, 15_000
    barrier = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^barrier}, 5_000
    events = drain([])
    assert reopened.record === outcome.record
    assert length(reopened.entries) == length(outcome.record.snapshot["journal"]["operations"])
    assert calls(events, Local, :run_state_operation) == []
    assert calls(events, PortSession, :fulfill) == []
    assert calls(events, CoreSegment, :consume_operation_observed) == []
    assert calls(events, Live, :publish_observed) == []
    assert calls(events, RuntimeStore, :put_fact) == []
    facts = calls(events, RuntimeStore, :get_fact)
    assert length(facts) == length(reopened.entries)
  end

  defp assert_data_only(term) when is_map(term) do
    refute is_struct(term)

    for {key, value} <- term do
      refute key in [
               "binding",
               "lease",
               "graph",
               "marks",
               "broker",
               "deadline",
               "call_id",
               :binding,
               :lease,
               :graph,
               :marks,
               :broker,
               :deadline,
               :call_id
             ]

      assert_data_only(key)
      assert_data_only(value)
    end
  end

  defp assert_data_only(term) when is_list(term), do: Enum.each(term, &assert_data_only/1)

  defp assert_data_only(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.each(&assert_data_only/1)

  defp assert_data_only(term) do
    refute is_pid(term) or is_port(term) or is_reference(term) or is_function(term)
  end

  defp json_roundtrip(term), do: term |> Jason.encode!() |> Jason.decode!()

  defp assert_code_worker_retired(events, registry) do
    {_, _, [^registry, _, :continuation, worker, _]} =
      one_call(events, ResourceRegistry, :register, fn [r, _, kind, _, _] ->
        r == registry and kind == :continuation
      end)

    refute Process.alive?(worker)
    assert Enum.any?(events, &match?({:trace, ^worker, :exit, :normal}, &1))

    identities =
      for {index, pid, [^worker]} <- calls(events, CodeMode.Worker, :os_identity) do
        {_, {:ok, identity}} = returned(events, index, pid, {CodeMode.Worker, :os_identity, 1})
        identity
      end

    assert [identity, same_identity] = identities
    assert same_identity === identity
    refute File.exists?("/proc/#{identity.pid}")
  end

  defp open_root(root, files, session_id, agent, store, action, state_options) do
    run_id = Ecto.UUID.generate()
    incarnation = store.incarnation
    caller = "synapsis:" <> session_id
    all_names = @names ++ [@caller_tool]

    identity = %{
      caller: caller,
      session_id: session_id,
      run_id: run_id,
      incarnation: incarnation,
      catalog_revision: 1
    }

    ceiling = %{
      caller: caller,
      run_id: run_id,
      grants: all_names,
      tool_revision: 1,
      tool_revisions: Map.new(all_names, &{&1, 1})
    }

    assert {:ok, session} = Session.start_link(owner_pid: self(), cleanup_timeout: 5_000)
    assert {:ok, binding} = Session.bind(session, ceiling, incarnation: incarnation)
    assert {:ok, native} = HostCodeMode.bundles(%{session_binding: binding}, ceiling, @names)
    assert {:ok, adapter} = AdapterHost.start_link(self())

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

    registration = SessionAdapter.workflow_effect_registration(adapter, run_id, incarnation)

    descriptor = %{
      tool_name: @caller_tool,
      tool_revision: 1,
      backend: CallerBackend,
      backend_context: %{
        observer: self(),
        adapter: adapter,
        action: action,
        state_options: state_options,
        workflow_effect_registration: registration,
        session_binding: binding,
        profiles_context: profiles_context,
        project_root: files,
        ceiling: ceiling,
        store: store,
        session_id: session_id,
        caller: caller,
        schema_runtime: %{
          node_executable: @node,
          helper_path: Path.join(@root, "packages/tool-host/src/workflow/schema-stdio.mjs")
        }
      },
      schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      safety: %{read_only: false, retry_safe: false, parallel_safe: false}
    }

    assert {:ok, catalog} = Catalog.compose([original], [descriptor], ceiling, all_names)
    snapshot = %{snapshot | issued_descriptors: catalog.registry.tools}
    pinned = Map.put(Map.take(catalog, [:registry, :tools, :authority]), :revision, 1)
    assert {:ok, snapshot} = Profiles.project_catalog(identity, snapshot, pinned)
    assert :ok = GenServer.call(adapter, {:install_root, {run_id, incarnation}, snapshot}, 5_000)

    assert {:ok, parent} =
             Headless.start_link(
               run_id: run_id,
               incarnation: incarnation,
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
             )

    assert {:ok, supervisor} = ResourceRegistry.worker_supervisor(binding.resource_registry)

    %{cleanup_supervisor: cleanup_supervisor} = :sys.get_state(binding.resource_registry)
    %{supervisor: task_supervisor} = :sys.get_state(parent)

    for pid <- [
          parent,
          session,
          binding.resource_registry,
          supervisor,
          task_supervisor,
          cleanup_supervisor
        ],
        do: :erlang.trace(pid, true, [:call, :procs, :set_on_spawn, {:tracer, self()}])

    on_exit(fn ->
      if Process.alive?(parent), do: GenServer.stop(parent, :normal, 5_000)
      if Process.alive?(session), do: GenServer.stop(session, :normal, 5_000)
      if Process.alive?(adapter), do: GenServer.stop(adapter, :normal, 5_000)
    end)

    %{
      parent: parent,
      session: session,
      adapter: adapter,
      binding: binding,
      identity: identity,
      store: store,
      snapshot: snapshot,
      registration: registration,
      files: files
    }
  end

  defp exercise(fixture) do
    assert {:ok, %{run_id: run_id}} = Headless.execute(fixture.parent, @root_source)
    assert run_id == fixture.identity.run_id

    assert_receive {:driver_outcome, owner, operation, {:ok, outcome}, before_parent,
                    after_parent},
                   70_000

    assert before_parent === after_parent
    assert before_parent.owner == fixture.parent
    assert before_parent.owner_alive
    assert before_parent.session_alive
    assert {:ok, _} = before_parent.validation
    assert operation.caller == fixture.identity.caller
    assert operation.run_id == run_id
    assert operation.incarnation == fixture.identity.incarnation
    assert {:ok, native} = Headless.await(fixture.parent, timeout: 20_000)
    assert native.status == :completed
    assert native.value === outcome.envelope
    assert native.nested_invocations == 1
    assert native.output == []
    refute native.output_truncated
    events = await_caller_exit(owner, [])
    barrier = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^barrier}, 5_000
    events = events ++ drain([])
    refute Process.alive?(owner)
    assert Process.alive?(fixture.parent)
    assert Process.alive?(fixture.session)

    assert Map.keys(:sys.get_state(fixture.adapter).tool_contexts) == [
             {run_id, fixture.identity.incarnation}
           ]

    {outcome, events, owner, operation}
  end

  defp close_root(fixture, events) do
    assert_code_worker_retired(events, fixture.binding.resource_registry)

    for pid <- [fixture.parent, fixture.session, fixture.adapter] do
      if pid == fixture.session, do: assert({:ok, %{status: :confirmed}} = Session.close(pid))
      ref = Process.monitor(pid)
      assert :ok = GenServer.stop(pid, :normal, 5_000)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end

    refute Process.alive?(fixture.binding.resource_registry)
    refute Process.alive?(fixture.parent)
    refute Process.alive?(fixture.session)
    refute Process.alive?(fixture.adapter)
    # Drain the old root's final trace events before opening the next root.
    barrier = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^barrier}, 5_000
    drain([])
  end

  defp install_observation do
    targets = @trace_targets

    for {module, _, _} = target <- targets do
      Code.ensure_loaded!(module)
      assert :erlang.trace_pattern(target, [{:_, [], [{:return_trace}]}], [:local]) > 0
    end

    on_exit(fn -> for target <- targets, do: :erlang.trace_pattern(target, false, [:local]) end)
  end

  defp await_caller_exit(owner, acc) do
    receive do
      {:trace, ^owner, :exit, :normal} = event ->
        Enum.reverse([event | acc])

      event when is_tuple(event) and elem(event, 0) in [:trace, :adapter_call] ->
        await_caller_exit(owner, [event | acc])
    after
      10_000 -> flunk("ordinary admitted state driver caller did not exit normally")
    end
  end

  defp drain(acc) do
    receive do
      event when is_tuple(event) and elem(event, 0) in [:trace, :adapter_call] ->
        drain([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp calls(events, module, function),
    do:
      for(
        {{:trace, pid, :call, {^module, ^function, args}}, index} <- Enum.with_index(events),
        do: {index, pid, args}
      )

  defp one_call(events, module, function, predicate) do
    assert [one] =
             Enum.filter(calls(events, module, function), fn {_, _, args} -> predicate.(args) end)

    one
  end

  defp returns(events, module, function, arity),
    do:
      for(
        {{:trace, pid, :return_from, {^module, ^function, ^arity}, value}, index} <-
          Enum.with_index(events),
        do: {index, pid, value}
      )

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

  defp commit_revisions(events),
    do:
      for(
        {_, _, {:ok, record}} <- returns(events, Continuations, :commit, 5),
        do: record.revision
      )

  defp cleanup(session_id, namespace) do
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
end
