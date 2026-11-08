defmodule Synapsis.Agent.Tools.Workflows.SegmentEffectDriverFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex.{CodeMode, Headless, ResourceRegistry, Session}
  alias Synapsis.Agent.Runtime.{SessionAdapter, Store}
  alias Synapsis.Agent.Tools.{Catalog, Filesystem, Policy, Profiles}
  alias Synapsis.Agent.Tools.CodeMode, as: HostCodeMode
  alias Synapsis.Agent.Tools.Workflows.{Effect, Journal, Segment}
  alias Synapsis.Filesystem.Local
  alias Synapsis.Runtime.Store, as: RuntimeStore
  alias Synapsis.Session.Store, as: SessionStore
  alias Synapsis.Workflow.{Continuations, JSON, Machine, Schema}
  alias Synapsis.Workflow.Schema.PortSession
  alias Synapsis.Workflow.Segment, as: CoreSegment

  @moduletag :tmp_dir
  @moduletag timeout: 180_000
  @root Path.expand("../../../../../../..", __DIR__)
  @node "/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node"
  @caller_tool "fixture_segment_effect_driver"
  @names ~w(exec wait synapsis::read synapsis::write synapsis::edit synapsis::ls)
  @source "// @exec: {\"yield_time_ms\": 1000}\nreturn await tools[input.tool_name](input.arguments);\n"
  @root_source "// @exec: {\"yield_time_ms\": 10000}\nreturn (await tools.fixture_segment_effect_driver({})).value;\n"
  @first ~S({"content":[{"type":"text","text":"first\n"}],"details":{"kind":"text","content":"first\n"}})
  @second ~S({"details":{"content":"second\n","kind":"text"},"content":[{"text":"second\n","type":"text"}]})
  @pipeline ~S(openclaw.invoke --tool synapsis::read --action read --args-json '{"path":"first.txt"}' | ask --prompt Review --schema '{"type":"string"}' --emit | clawd.invoke --tool synapsis::read --action read --args-json '{"path":"second.txt"}')
  @same_stage_pipeline ~S(openclaw.invoke --tool synapsis::read --action read --args-json '{"path":"first.txt"}' | ask --prompt Review --schema '{"type":"string"}' | clawd.invoke --tool synapsis::read --action read --args-json '{"path":"second.txt"}')
  @trace_targets [
    {Segment, :run_effects, 3},
    {Segment, :resume_effects, 5},
    {Journal, :run_segment, 4},
    {Journal, :consume_segment, 3},
    {Journal, :reopen_segment, 5},
    {Effect, :run, 2},
    {Filesystem, :execute, 1},
    {Filesystem, :validate_prepared_receipt, 2},
    {Local, :prepare_target, 5},
    {Profiles, :build, 4},
    {Headless, :start_link, 1},
    {Headless, :execute, 3},
    {ResourceRegistry, :register, 5},
    {ResourceRegistry, :release, 3},
    {CodeMode.Worker, :os_identity, 1},
    {RuntimeStore, :put_fact, 4},
    {RuntimeStore, :get_fact, 3},
    {Continuations, :create, 4},
    {Continuations, :commit, 5},
    {CoreSegment, :new, 2},
    {CoreSegment, :advance, 1},
    {CoreSegment, :resume, 2},
    {Schema, :advance_pending, 3},
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
      adapters = adapters(context.expected, self())

      result =
        case context.action do
          {:run, pipeline} ->
            Segment.run_effects(pipeline, supplied, adapters)

          {:resume, id, revision, raw} ->
            Segment.resume_effects(id, revision, raw, supplied, adapters)
        end

      after_parent = parent_state(operation)
      barrier = :erlang.trace_delivered(:all)

      receive do
        {:trace_delivered, :all, ^barrier} -> :ok
      after
        5_000 -> raise "ordinary effect driver trace did not drain"
      end

      send(
        context.observer,
        {:driver_outcome, self(), operation, adapters, result, before_parent, after_parent}
      )

      # Retain process observation until this actual admitted caller exits.
      case result do
        {:ok, outcome} -> {:ok, %{value: outcome.envelope, is_error: false}}
        error -> error
      end
    end

    # These functions only construct an explicit declared native request or
    # return declared raw source JSON. They execute no effect and encode no map.
    # Capture the fresh caller identity so the two ephemeral closures are distinct.
    def adapters(expected, owner) do
      %{
        request: fn machine_request, actual_record ->
          request(machine_request, actual_record, expected, owner)
        end,
        response_json: fn verified_effect -> response_json(verified_effect, expected, owner) end
      }
    end

    def request(machine_request, actual_record, expected, _owner) do
      {:ok,
       %{
         correlation: %{
           workflow_id: actual_record.id,
           request_id: machine_request["id"],
           segment: machine_request["segment"]
         },
         target: expected.target,
         limits: %{
           timeout_ms: 20_000,
           effect_timeout_ms: 15_000,
           commit_timeout_ms: 5_000,
           cleanup_timeout_ms: 5_000,
           output_limit: 65_536,
           work: 4
         }
       }}
    end

    def response_json(verified_effect, expected, _owner) do
      case verified_effect.request.target.arguments do
        %{"path" => "first.txt"} -> {:ok, expected.first_json}
        %{"path" => "second.txt"} -> {:ok, expected.second_json}
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

  test "effect driver consumes, checkpoints, retires its root and explicitly resumes in a fresh native root",
       %{tmp_dir: root} do
    run_checkpoint_scenario(root, "next_stage")
  end

  test "same-stage effect driver preserves its checkpoint, retires its root and consumes input in a fresh native root",
       %{tmp_dir: root} do
    run_checkpoint_scenario(root, "same_stage")
  end

  defp run_checkpoint_scenario(root, mode) do
    pipeline = if mode == "same_stage", do: @same_stage_pipeline, else: @pipeline
    install_observation()
    assert File.regular?(@node)
    assert :ok = SessionStore.ensure_started()
    files = Path.join(root, "files")
    File.mkdir!(files)
    File.write!(Path.join(files, "first.txt"), "first\n")
    File.write!(Path.join(files, "second.txt"), "second\n")
    session_id = Ecto.UUID.generate()
    assert {:ok, store} = Store.new(1)

    assert {:ok, agent} =
             Synapsis.AgentConfigs.create(%{
               name: "segment-effect-driver-#{session_id}",
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
      cleanup(session_id, store.namespace)
    end)

    first = open_root(root, files, session_id, agent, store, {:run, pipeline}, "first.txt")
    {initial, initial_events, initial_owner, first_operation, first_adapters} = exercise(first)
    assert initial.record.session_id == session_id
    assert initial.record.agent_id == agent.id
    assert initial.record.revision == 5
    assert initial.record.snapshot["revision"] == 5
    assert initial.record.snapshot["version"] == 2
    assert initial.record.snapshot["source"] == %{"kind" => "inline", "pipeline" => pipeline}
    assert initial.record.snapshot["consumed_effects"] == 1
    assert initial.record.snapshot["machine"]["phase"] == "checkpoint"
    assert initial.record.snapshot["machine"]["segment"] == 0

    assert initial.record.snapshot["machine"]["next_request"] ==
             if(mode == "same_stage", do: 4, else: 3)

    checkpoint = initial.record.snapshot["machine"]["checkpoint"]
    assert checkpoint["mode"] == mode
    assert checkpoint["stage_index"] == 1

    if mode == "same_stage" do
      assert_same_stage_checkpoint(initial.record.snapshot["machine"])
    else
      assert checkpoint["replay_items"] == []
    end

    token = initial.envelope["requiresInput"]["resumeToken"]
    assert "workflow-segment.v2." <> encoded = token

    assert encoded |> Base.url_decode64!(padding: false) |> Jason.decode!() ==
             %{"workflowId" => initial.record.id, "revision" => 5}

    assert initial.envelope == %{
             "ok" => true,
             "status" => "needs_input",
             "output" => [],
             "requiresApproval" => nil,
             "requiresInput" => %{
               "type" => "input_request",
               "prompt" => "Review",
               "responseSchema" => %{"type" => "string"},
               "resumeToken" => token
             }
           }

    assert [{_, _, [^pipeline, [version: 2]]}] = calls(initial_events, CoreSegment, :new)
    assert [{_, _, {:ok, created}}] = returns(initial_events, Continuations, :create, 4)
    assert created.revision == 1
    assert created.snapshot["revision"] == 1
    assert created.snapshot["machine"]["phase"] == "construct"
    assert created.snapshot["consumed_effects"] == 0
    assert created.snapshot["journal"] == %{"kind" => "workflow", "version" => 1, "effects" => []}
    assert commit_revisions(initial_events) == [2, 3, 4, 5]
    first_step = assert_step(first, first_operation, initial.record, initial_events, 0)
    assert first_step.before === created
    assert first_step.consumed.snapshot["journal"] === initial.record.snapshot["journal"]
    assert first_step.consumed.snapshot["consumed_effects"] == 1
    assert first_step.consumed_ack < commit_call(initial_events, 4)

    assert schema_requests(initial_events) ==
             if(mode == "same_stage",
               do: [
                 ["compile_schema", "ask_constructor"],
                 ["compile_schema", "request_metadata"]
               ],
               else: [["compile_schema", "ask_constructor"]]
             )

    assert_schema_retirement(first, initial, initial_events, initial_owner)
    assert Continuations.load(session_id, initial.record.id) === {:ok, initial.record}

    assert initial.record.snapshot ===
             initial.record.snapshot |> Jason.encode!() |> Jason.decode!()

    for {index, _, _} <- calls(initial_events, Schema, :advance_pending),
        do: assert(first_step.consumed_ack < index)

    first_fact = first_step.fact
    first_aggregate = first_step.aggregate
    first_root_aggregate = assert_root_receipt(first, first_operation, initial.envelope)
    first_nodes = initial.record.snapshot["machine"]["heap"]["nodes"]
    assert_ordered_root(first_step.consumed.snapshot["machine"], @first, ["content", "details"])
    close_root(first, initial_events)
    refute Process.alive?(initial_owner)

    second_store = %{store | incarnation: 2}

    second =
      open_root(
        root,
        files,
        session_id,
        agent,
        second_store,
        {:resume, initial.record.id, 5, ~S("approved")},
        "second.txt"
      )

    assert second.store.namespace === first.store.namespace
    assert second.identity.session_id === first.identity.session_id
    assert second.identity.run_id != first.identity.run_id
    assert second.identity.incarnation == 2
    assert second.parent != first.parent
    assert second.session != first.session
    assert second.adapter != first.adapter
    assert second.binding != first.binding
    assert second.binding.resource_registry != first.binding.resource_registry
    assert second.registration !== first.registration
    assert second.snapshot.scope.incarnation == 2

    assert second.snapshot.issued_descriptors["synapsis::read"].backend_context.prepared_target_resolver !==
             first.snapshot.issued_descriptors["synapsis::read"].backend_context.prepared_target_resolver

    {resumed, resume_events, resume_owner, second_operation, second_adapters} = exercise(second)
    assert resume_owner != initial_owner
    assert second_adapters.request !== first_adapters.request
    assert second_adapters.response_json !== first_adapters.response_json
    assert resumed.record.id === initial.record.id
    assert resumed.record.session_id === session_id
    assert resumed.record.agent_id === agent.id
    assert resumed.record.revision == 10
    assert resumed.record.snapshot["revision"] == 10
    assert resumed.record.snapshot["source"] === initial.record.snapshot["source"]
    assert resumed.record.snapshot["consumed_effects"] == 2
    assert resumed.record.snapshot["machine"]["phase"] == "completed"
    assert resumed.record.snapshot["machine"]["segment"] == 1

    assert Enum.map(resumed.record.snapshot["machine"]["program"], & &1["name"]) ==
             if(mode == "same_stage", do: ["ask", "clawd.invoke"], else: ["clawd.invoke"])

    if mode == "same_stage" do
      assert resumed.record.snapshot["machine"]["resume_input"] === %{
               "state" => checkpoint["command_input"],
               "response" => %{"type" => "string", "value" => "approved"},
               "consumed" => true
             }

      [ask, _invoke] = resumed.record.snapshot["machine"]["frames"]
      assert ask["request_index"] == 1
      assert [answered] = ask["request_history"]
      assert_ask_input(answered, resumed.record.snapshot["machine"]["heap"])
      assert answered["response"] === %{"type" => "string", "value" => "approved"}
    end

    assert resumed.envelope == %{
             "ok" => true,
             "status" => "ok",
             "output" => [Jason.decode!(@second)],
             "requiresApproval" => nil
           }

    assert [] == calls(resume_events, Continuations, :create)
    assert commit_revisions(resume_events) == [6, 7, 8, 9, 10]
    assert_resume_claim(second, initial.record, first_step, resume_events, mode)
    second_step = assert_step(second, second_operation, resumed.record, resume_events, 1, mode)
    assert second_step.before.revision == 6
    assert second_step.before.snapshot["journal"] === initial.record.snapshot["journal"]
    assert second_step.before.snapshot["consumed_effects"] == 1
    assert second_step.consumed_ack < commit_call(resume_events, 9)
    assert resumed.record.snapshot["journal"] === second_step.consumed.snapshot["journal"]

    assert hd(resumed.record.snapshot["journal"]["effects"]) ===
             hd(initial.record.snapshot["journal"]["effects"])

    assert schema_requests(resume_events) ==
             if(mode == "same_stage",
               do: [
                 ["compile_schema", "resume_metadata"],
                 ["compile_schema", "saved_response"],
                 ["validate_response", "saved_response"],
                 ["compile_schema", "ask_constructor"],
                 ["compile_schema", "request_metadata"],
                 ["compile_schema", "request_response"],
                 ["validate_response", "request_response"]
               ],
               else: [
                 ["compile_schema", "saved_response"],
                 ["validate_response", "saved_response"]
               ]
             )

    assert_schema_retirement(second, resumed, resume_events, resume_owner)
    assert resumed.retirement.helper.os_pid != initial.retirement.helper.os_pid
    assert_ordered_root(second_step.consumed.snapshot["machine"], @second, ["details", "content"])

    for {id, node} <- first_nodes,
        do: assert(resumed.record.snapshot["machine"]["heap"]["nodes"][id] === node)

    [final_root] = resumed.record.snapshot["machine"]["items"]
    assert {:ok, @second} = JSON.stringify(final_root, resumed.record.snapshot["machine"]["heap"])

    assert {:ok, %{envelope: envelope, text: text}} =
             CoreSegment.render_envelope(resumed.record.snapshot, "unused")

    assert envelope === resumed.envelope
    assert text == ordered_complete_envelope()
    assert Continuations.load(session_id, initial.record.id) === {:ok, resumed.record}

    assert resumed.record.snapshot ===
             resumed.record.snapshot |> Jason.encode!() |> Jason.decode!()

    assert_root_receipt(second, second_operation, resumed.envelope)
    close_root(second, resume_events)
    refute Process.alive?(resume_owner)

    assert RuntimeStore.get_fact(
             session_id,
             :workflow_effect_receipt,
             first_step.reference["fact_id"]
           ) ===
             {:ok, first_fact}

    assert Store.load(second.store, first_step.effect.locator.run_id) === {:ok, first_aggregate}
    assert Store.load(second.store, first.identity.run_id) === {:ok, first_root_aggregate}
    assert File.read!(Path.join(files, "first.txt")) == "first\n"
    assert File.read!(Path.join(files, "second.txt")) == "second\n"

    events = initial_events ++ resume_events
    assert length(calls(events, Effect, :run)) == 2
    assert length(calls(events, Journal, :run_segment)) == 2
    assert length(calls(events, Journal, :consume_segment)) == 2

    assert Enum.map(calls(events, Filesystem, :execute), fn {_, _, [op]} ->
             {op.run_id, op.arguments}
           end) == [
             {first_step.effect.locator.run_id, %{"path" => "first.txt"}},
             {second_step.effect.locator.run_id, %{"path" => "second.txt"}}
           ]

    assert first_step.effect.locator.run_id != second_step.effect.locator.run_id

    assert first_step.effect.retirement.resource_handle !=
             second_step.effect.retirement.resource_handle
  end

  defp assert_step(fixture, operation, final_record, events, ordinal, mode \\ "next_stage") do
    pending_revision = if ordinal == 0, do: 2, else: 7
    path = if ordinal == 0, do: "first.txt", else: "second.txt"
    raw = if ordinal == 0, do: @first, else: @second
    text = if ordinal == 0, do: "first\n", else: "second\n"

    request_id =
      cond do
        ordinal == 0 -> "invoke:1"
        mode == "same_stage" -> "invoke:11"
        true -> "invoke:5"
      end

    stage_index = if ordinal == 1 and mode == "same_stage", do: 1, else: 0
    command = if ordinal == 0, do: "openclaw.invoke", else: "clawd.invoke"
    workflow_id = final_record.id

    {adapter_index, adapter_pid, [request, before, _, owner]} =
      one_call(events, CallerBackend, :request, fn _ -> true end)

    assert adapter_pid == owner
    assert before.revision == pending_revision - 1
    assert before.snapshot["revision"] == before.revision

    assert request == %{
             "id" => request_id,
             "kind" => "invoke",
             "command" => command,
             "segment" => ordinal,
             "stage_index" => stage_index,
             "body" => ~s({"tool":"synapsis::read","action":"read","args":{"path":"#{path}"}})
           }

    {adapter_ack, {:ok, native}} =
      returned(events, adapter_index, adapter_pid, {CallerBackend, :request, 4})

    assert native == %{
             correlation: %{workflow_id: workflow_id, request_id: request_id, segment: ordinal},
             target: %{
               tool_name: "synapsis::read",
               tool_revision: 1,
               arguments: %{"path" => path}
             },
             limits: %{
               timeout_ms: 20_000,
               effect_timeout_ms: 15_000,
               commit_timeout_ms: 5_000,
               cleanup_timeout_ms: 5_000,
               output_limit: 65_536,
               work: 4
             }
           }

    {journal_call, journal_pid, [actual, awaiting, ^native, supplied]} =
      one_call(events, Journal, :run_segment, fn _ -> true end)

    assert adapter_ack < journal_call
    assert actual === before
    assert awaiting["revision"] == before.revision
    assert awaiting["machine"]["pending_request"] === request
    assert awaiting["source"] === final_record.snapshot["source"]
    assert supplied.operation === operation
    assert supplied.workflow_effect_registration === fixture.registration
    assert supplied.profiles_snapshot === fixture.snapshot
    assert supplied.store === fixture.store

    {pending_call, pending_pid, [session_id, ^workflow_id, revision, pending, _]} =
      one_call(events, Continuations, :commit, fn [_, _, revision, _, _] ->
        revision == pending_revision - 1
      end)

    assert session_id == fixture.identity.session_id
    assert revision == before.revision
    assert pending["revision"] == pending_revision
    assert pending["machine"] === awaiting["machine"]
    assert pending["consumed_effects"] == ordinal
    entry = List.last(pending["journal"]["effects"])
    assert entry["state"] == "pending"
    assert entry["pending_revision"] == pending_revision

    assert entry["request"]["correlation"] == %{
             "workflow_id" => workflow_id,
             "request_id" => request_id,
             "segment" => ordinal
           }

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

    {pending_ack, {:ok, acknowledged}} =
      returned(events, pending_call, pending_pid, {Continuations, :commit, 5})

    assert acknowledged.snapshot === pending
    assert acknowledged.revision == pending_revision
    {effect_call, effect_pid, [^native, _]} = one_call(events, Effect, :run, fn _ -> true end)
    {effect_ack, {:ok, effect}} = returned(events, effect_call, effect_pid, {Effect, :run, 2})
    assert pending_ack < effect_call
    assert effect.request === native
    assert effect.consumer_value === Jason.decode!(raw)
    assert effect.locator.effect_request === native
    assert effect.locator.parent_run_id == operation.run_id
    assert effect.locator.parent_incarnation == operation.incarnation
    assert effect.locator.parent_invocation_id == operation.invocation_id
    aggregate = assert_native(fixture, operation, effect, path, text, events)

    {journal_ack, {:ok, %{record: settled_from_run, effect: ^effect}}} =
      returned(events, journal_call, journal_pid, {Journal, :run_segment, 4})

    {response_call, response_pid, [^effect, _, ^owner]} =
      one_call(events, CallerBackend, :response_json, fn _ -> true end)

    {response_ack, {:ok, ^raw}} =
      returned(events, response_call, response_pid, {CallerBackend, :response_json, 3})

    assert effect_ack < response_call
    assert journal_ack < response_call

    {consume_call, consume_pid, [settled, ^raw, _]} =
      one_call(events, Journal, :consume_segment, fn _ -> true end)

    assert response_ack < consume_call
    assert settled === settled_from_run
    assert settled.revision == pending_revision + 1
    assert settled.snapshot["machine"] === awaiting["machine"]
    assert settled.snapshot["consumed_effects"] == ordinal

    {_, {:ok, %{record: consumed, effect: ^effect}}} =
      returned(events, consume_call, consume_pid, {Journal, :consume_segment, 3})

    assert consumed.revision == pending_revision + 2
    assert consumed.snapshot["consumed_effects"] == ordinal + 1
    assert consumed.snapshot["journal"] === settled.snapshot["journal"]

    assert {:continue, expected_machine} =
             Machine.advance(awaiting["machine"], %{"id" => request_id, "response_json" => raw})

    assert consumed.snapshot["machine"] === expected_machine
    assert consumed.snapshot["machine"]["pending_request"] == nil
    assert {:ok, %{consumed_effects: cursor}} = CoreSegment.inspect_snapshot(consumed.snapshot)
    assert cursor == ordinal + 1
    reference = List.last(settled.snapshot["journal"]["effects"])["receipt"]
    assert reference["namespace"] == fixture.store.namespace
    assert reference["incarnation"] == fixture.identity.incarnation
    assert reference["run_id"] == effect.locator.run_id

    {fact_call, fact_pid, [^session_id, :workflow_effect_receipt, fact_id, fact]} =
      one_call(events, RuntimeStore, :put_fact, fn [_, kind, _, _] ->
        kind == :workflow_effect_receipt
      end)

    assert fact_id == workflow_id <> ":" <> Integer.to_string(pending_revision)
    assert reference["fact_id"] == fact_id

    assert fact === %{
             version: 1,
             workflow_id: workflow_id,
             agent_id: final_record.agent_id,
             pending_revision: pending_revision,
             effect: effect
           }

    {fact_ack, :ok} = returned(events, fact_call, fact_pid, {RuntimeStore, :put_fact, 4})

    {settled_call, settled_pid, [_, _, _, settled_snapshot, _]} =
      one_call(events, Continuations, :commit, fn [_, _, revision, _, _] ->
        revision == pending_revision
      end)

    {settled_ack, {:ok, ^settled}} =
      returned(events, settled_call, settled_pid, {Continuations, :commit, 5})

    assert fact_ack < settled_call
    assert settled_snapshot === settled.snapshot

    {consumed_call, consumed_pid, [_, _, _, consumed_snapshot, _]} =
      one_call(events, Continuations, :commit, fn [_, _, revision, _, _] ->
        revision == pending_revision + 1
      end)

    {consumed_ack, {:ok, ^consumed}} =
      returned(events, consumed_call, consumed_pid, {Continuations, :commit, 5})

    assert settled_ack < consumed_call
    assert consumed_snapshot === consumed.snapshot

    assert List.last(settled.snapshot["journal"]["effects"]) ===
             Map.merge(entry, %{
               "state" => "settled",
               "settled_revision" => pending_revision + 1,
               "receipt" => reference
             })

    %{
      before: before,
      consumed: consumed,
      consumed_ack: consumed_ack,
      effect: effect,
      reference: reference,
      fact: fact,
      aggregate: aggregate
    }
  end

  defp assert_native(fixture, parent_operation, effect, path, text, events) do
    child_run = effect.locator.run_id
    incarnation = fixture.identity.incarnation
    assert {:ok, aggregate} = Store.load(fixture.store, child_run)
    record = aggregate.run
    receipt = effect.receipt
    outer = receipt.outer_intent.operation
    target = receipt.target_intent.operation
    assert record.state == :completed
    assert aggregate.incarnation == incarnation

    assert receipt === %{
             version: 1,
             run_id: child_run,
             incarnation: incarnation,
             turn_id: outer.turn_id,
             catalog_revision: 1,
             catalog_digest: record.context.headless_catalog["descriptor_digest"],
             outer_intent: record.execution_intents["tool:#{outer.invocation_id}"],
             target_intent: record.execution_intents["tool:#{target.invocation_id}"],
             target_result: %{
               content: [%{type: "text", text: text}],
               details: %{kind: "text", content: text},
               is_error: false
             },
             target_presentation: nil,
             final_revision: aggregate.revision
           }

    assert receipt.target_intent.status == :consumed
    assert receipt.outer_intent.status == :consumed
    intents = Map.values(record.execution_intents)

    assert Enum.filter(intents, &(&1.operation.tool_name == "synapsis::read")) === [
             receipt.target_intent
           ]

    assert Enum.filter(intents, &(&1.operation.tool_name == "exec")) === [receipt.outer_intent]

    for intent <- intents -- [receipt.target_intent, receipt.outer_intent] do
      assert intent.operation.tool_name == "wait"
      assert intent.type == :tool
      assert intent.status == :consumed
    end

    assert Enum.sort(Map.keys(record.tool_results)) ==
             Enum.sort(Enum.map(intents, & &1.operation.invocation_id))

    assert record.tool_results[target.invocation_id] === receipt.target_result

    assert record.tool_results[outer.invocation_id] === %{
             status: :completed,
             value: effect.consumer_value,
             output: [],
             output_truncated: false,
             is_error: false
           }

    assert record.context.conversation.headless_result.value === effect.consumer_value
    assert record.context.conversation.headless_result.nested_invocations == 1
    assert Map.get(record, :provider_attempts, %{}) == %{}
    assert outer.arguments === @source
    assert target.tool_name == "synapsis::read"
    assert target.arguments === %{"path" => path}
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

    {build_call, build_pid, [context, identity, _, _]} =
      one_call(events, Profiles, :build, fn [_, identity, _, _] ->
        identity.run_id == child_run
      end)

    {_, {:ok, %{bundle: bundle, snapshot: snapshot}}} =
      returned(events, build_call, build_pid, {Profiles, :build, 4})

    assert identity.session_id == fixture.identity.session_id
    assert identity.incarnation == incarnation
    assert Enum.sort(Map.keys(bundle.registry.tools)) == Enum.sort(~w(exec wait synapsis::read))
    assert snapshot.permission === fixture.snapshot.permission
    assert snapshot.evidence === fixture.snapshot.evidence
    key = {child_run, incarnation}
    parent_key = {fixture.identity.run_id, incarnation}

    assert [{register_message, caller, {:ok, ticket}, reserved}] =
             adapter_calls(events, :workflow_effect_register, fn message ->
               elem(message, 3).run_id == child_run
             end)

    {_, effect_owner, _} = one_call(events, Effect, :run, fn _ -> true end)
    assert caller == effect_owner
    assert elem(register_message, 2).catalog === parent_operation.backend_context.catalog_snapshot
    assert elem(register_message, 2).authority === parent_operation.effective_authority
    assert reserved[key].workflow.phase == :pending
    assert reserved[key].prepared_targets == %{}
    assert reserved[key].prepared_targets_closed?
    assert context.tool_filesystem === ticket.tool_filesystem

    assert [{_, ^caller, {:ok, host_context}, active}] =
             adapter_calls(events, :workflow_effect_activate, fn message ->
               elem(message, 1) == key
             end)

    assert active[key].snapshot === snapshot
    assert active[key].workflow.phase == :active
    assert active[key].prepared_targets == %{}
    refute active[key].prepared_targets_closed?
    assert host_context.filesystem_preparation === ticket.preparation
    child_descriptor = bundle.registry.tools["synapsis::read"]
    parent_descriptor = fixture.snapshot.issued_descriptors["synapsis::read"]

    assert child_descriptor === %{
             parent_descriptor
             | backend_context:
                 parent_descriptor.backend_context
                 |> Map.merge(%{run_id: child_run, incarnation: incarnation, catalog_revision: 1})
                 |> Map.put(:prepared_target_resolver, ticket.preparation.fetch)
           }

    assert ticket.preparation.fetch !== parent_descriptor.backend_context.prepared_target_resolver

    assert [{_, _, {:ok, prepared}, sealed}] =
             adapter_calls(events, :filesystem_target_seal, fn message ->
               elem(message, 1).run_id == child_run
             end)

    assert sealed[parent_key].prepared_targets == %{}
    assert [{ledger_key, ledger_entry}] = Map.to_list(sealed[key].prepared_targets)
    assert ledger_entry.state == :sealed
    assert ledger_entry.record === prepared
    assert ledger_key === {child_run, incarnation, 1, target.invocation_id, "synapsis::read", 1}
    assert prepared.key === ledger_key
    assert prepared.public_path == path
    assert prepared.original_path == path
    assert prepared.target === {:local, Path.join(fixture.files, path), path}
    assert prepared.raw_arguments_digest === digest(effect.request.target.arguments)
    assert prepared.prepared_arguments_digest === digest(target.arguments)

    fetches =
      adapter_calls(events, :filesystem_target_fetch, fn message ->
        elem(message, 1).run_id == child_run
      end)

    assert fetches != []

    for {_, _, result, state} <- fetches do
      assert result === {:ok, prepared}
      assert state[key].prepared_targets[ledger_key].record === prepared
      assert state[parent_key].prepared_targets == %{}
    end

    {receipt_call, receipt_pid, [raw, live_operation]} =
      one_call(events, Filesystem, :validate_prepared_receipt, fn [_, op] ->
        op.run_id == child_run
      end)

    assert raw === %{"path" => path}
    assert live_operation.arguments === target.arguments
    assert live_operation.backend_context.prepared_target_resolver === ticket.preparation.fetch

    {_, :ok} =
      returned(events, receipt_call, receipt_pid, {Filesystem, :validate_prepared_receipt, 2})

    {_, _, [executed]} =
      one_call(events, Filesystem, :execute, fn [op] -> op.run_id == child_run end)

    assert executed.arguments === target.arguments

    {start_call, start_pid, [options]} =
      one_call(events, Headless, :start_link, fn [options] -> options[:run_id] == child_run end)

    {_, {:ok, child}} = returned(events, start_call, start_pid, {Headless, :start_link, 1})
    assert options[:hooks] == Policy
    assert options[:registry] === bundle.registry
    assert options[:tools] === bundle.tools
    assert options[:authority] === bundle.authority
    assert options[:host_context] === host_context
    assert options[:session_binding] === active[key].workflow.binding
    assert options[:session_binding].session != fixture.session
    assert options[:session_binding].resource_registry != fixture.binding.resource_registry
    refute Keyword.has_key?(options, :provider)

    {_, _, [^child, @source, execution]} =
      one_call(events, Headless, :execute, fn [pid, _, _] -> pid == child end)

    assert execution === [
             input: %{"tool_name" => "synapsis::read", "arguments" => %{"path" => path}}
           ]

    registry = fixture.binding.resource_registry
    handle = effect.retirement.resource_handle

    {release_call, release_pid, [^registry, ^handle, owner_id]} =
      one_call(events, ResourceRegistry, :release, fn [r, h, _] ->
        r == registry and h == handle
      end)

    {release_ack, {:ok, :ok}} =
      returned(events, release_call, release_pid, {ResourceRegistry, :release, 3})

    assert owner_id == fixture.binding.owner_id

    assert effect.retirement === %{
             resource_handle: handle,
             release: :confirmed,
             headless: :normal,
             session: :normal,
             registry: :normal
           }

    assert {:ok, %{status: :confirmed}} =
             ResourceRegistry.cleanup_status(registry, handle, owner_id)

    assert receipt_call < release_call

    {fact_call, _, _} =
      one_call(events, RuntimeStore, :put_fact, fn [_, kind, _, _] ->
        kind == :workflow_effect_receipt
      end)

    assert release_ack < fact_call

    for pid <- [
          child,
          options[:session_binding].session,
          options[:session_binding].resource_registry
        ] do
      assert Enum.any?(events, &match?({:trace, ^pid, :exit, :normal}, &1))
      refute Process.alive?(pid)
    end

    assert_code_worker_retired(events, options[:session_binding].resource_registry)

    assert [{_, _, :ok, released}] =
             adapter_calls(events, :workflow_effect_release, fn message ->
               elem(message, 1) == key
             end)

    assert Map.keys(released) == [parent_key]
    assert released[parent_key].snapshot === fixture.snapshot
    assert released[parent_key].prepared_targets == %{}
    refute released[parent_key].prepared_targets_closed?
    aggregate
  end

  defp assert_same_stage_checkpoint(machine) do
    checkpoint = machine["checkpoint"]
    assert checkpoint["halted_at"] == %{"index" => 1, "name" => "ask", "in_place" => true}
    # Invoke emits an iterator, so the saved ask state resumes without replaying
    # its drained input. The consumed native result remains in the original heap.
    assert checkpoint["replay_items"] == []
    assert_ordered_root(machine, @first, ["content", "details"])
    assert checkpoint["command_input"]["history"] == []
    assert_ask_input(checkpoint["command_input"]["pending"], machine["heap"])
    assert {:ok, request_json} = JSON.stringify(checkpoint["request"], machine["heap"])

    assert Jason.decode!(request_json) == %{
             "type" => "input_request",
             "prompt" => "Review",
             "responseSchema" => %{"type" => "string"},
             "items" => [],
             "commandInput" => %{
               "history" => [],
               "pending" => %{
                 "requestIndex" => 0,
                 "metadata" => %{
                   "prompt" => "Review",
                   "responseSchema" => %{"type" => "string"},
                   "signature" => ~S({"prompt":"Review","responseSchema":{"type":"string"}})
                 },
                 "suspendedState" => %{"type" => "ask"}
               }
             }
           }
  end

  defp assert_ask_input(entry, heap) do
    assert entry["requestIndex"] == 0

    assert entry["metadata"] == %{
             "prompt" => "Review",
             "responseSchema" => entry["metadata"]["responseSchema"],
             "signature" => ~S({"prompt":"Review","responseSchema":{"type":"string"}})
           }

    assert {:ok, ~S({"type":"string"})} =
             JSON.stringify(entry["metadata"]["responseSchema"], heap)

    assert {:ok, ~S({"type":"ask"})} = JSON.stringify(entry["suspendedState"], heap)
  end

  defp assert_resume_claim(fixture, retained, first_step, events, mode) do
    {reopen_call, reopen_pid, [session_id, agent_id, id, 5, _]} =
      one_call(events, Journal, :reopen_segment, fn _ -> true end)

    assert session_id == retained.session_id
    assert agent_id == retained.agent_id
    assert id == retained.id

    {reopen_ack, {:ok, reopened}} =
      returned(events, reopen_call, reopen_pid, {Journal, :reopen_segment, 5})

    assert reopened.record === retained
    assert [%{state: :settled, effect: effect}] = reopened.entries
    assert effect === first_step.effect

    assert Enum.any?(calls(events, RuntimeStore, :get_fact), fn {index, _, [sid, kind, fact_id]} ->
             index > reopen_call and index < reopen_ack and sid == session_id and
               kind == :workflow_effect_receipt and fact_id == first_step.reference["fact_id"]
           end)

    [{fact_call, fact_pid, _}] =
      Enum.filter(calls(events, RuntimeStore, :get_fact), fn {index, _, [sid, kind, fact_id]} ->
        index > reopen_call and index < reopen_ack and sid == session_id and
          kind == :workflow_effect_receipt and fact_id == first_step.reference["fact_id"]
      end)

    {fact_ack, {:ok, fact}} = returned(events, fact_call, fact_pid, {RuntimeStore, :get_fact, 3})
    assert reopen_call < fact_call
    assert fact_ack < reopen_ack
    assert fact === first_step.fact

    {resume_call, _, [snapshot, response]} =
      one_call(events, CoreSegment, :resume, fn _ -> true end)

    assert reopen_ack < resume_call
    assert snapshot === retained.snapshot
    assert response === ~S("approved")

    {claim_call, claim_pid, [^session_id, ^id, 5, claim, _]} =
      one_call(events, Continuations, :commit, fn [_, _, revision, _, _] -> revision == 5 end)

    {claim_ack, {:ok, claimed}} =
      returned(events, claim_call, claim_pid, {Continuations, :commit, 5})

    assert claimed.revision == 6
    assert claimed.snapshot === claim
    assert claim["revision"] == 6
    assert claim["source"] === retained.snapshot["source"]
    assert claim["journal"] === retained.snapshot["journal"]
    assert claim["consumed_effects"] == 1
    assert claim["machine"]["phase"] == "construct"
    assert claim["machine"]["frames"] == []
    assert claim["machine"]["stack"] == [%{"op" => "construct"}]
    assert claim["machine"]["segment"] == 1

    if mode == "same_stage" do
      assert Enum.map(claim["machine"]["program"], & &1["name"]) == ["ask", "clawd.invoke"]

      assert claim["machine"]["streams"]["s0"]["items"] ===
               retained.snapshot["machine"]["checkpoint"]["replay_items"]

      assert claim["machine"]["streams"]["s0"]["kind"] == "array"
      assert claim["machine"]["streams"]["s0"]["items"] == []
      assert claim["machine"]["heap"] === retained.snapshot["machine"]["heap"]
      assert_ordered_root(claim["machine"], @first, ["content", "details"])

      assert claim["machine"]["resume_input"] === %{
               "state" => retained.snapshot["machine"]["checkpoint"]["command_input"],
               "response" => %{"type" => "string", "value" => "approved"},
               "consumed" => false
             }
    else
      assert claim["machine"]["streams"]["s0"]["items"] == [
               %{"type" => "string", "value" => "approved"}
             ]
    end

    schema_phases =
      for {index, pid, [_broker, request, _heap, _]} <- calls(events, PortSession, :fulfill) do
        {ack, {:ok, receipt}} = returned(events, index, pid, {PortSession, :fulfill, 4})
        assert receipt["id"] == request["id"]
        assert receipt["result"] == "ok"
        phase = if index < claim_call, do: :before_claim, else: :after_claim

        if phase == :before_claim do
          assert ack < claim_call
        else
          assert claim_ack < index
          assert ack < commit_call(events, 6)
          [{request_call, _, _}] = calls(events, CallerBackend, :request)
          [{effect_call, _, _}] = calls(events, Effect, :run)
          assert ack < request_call
          assert ack < effect_call
        end

        {phase, request["kind"], request["boundary"]}
      end

    assert schema_phases ==
             if(mode == "same_stage",
               do: [
                 {:before_claim, "compile_schema", "resume_metadata"},
                 {:before_claim, "compile_schema", "saved_response"},
                 {:before_claim, "validate_response", "saved_response"},
                 {:after_claim, "compile_schema", "ask_constructor"},
                 {:after_claim, "compile_schema", "request_metadata"},
                 {:after_claim, "compile_schema", "request_response"},
                 {:after_claim, "validate_response", "request_response"}
               ],
               else: [
                 {:before_claim, "compile_schema", "saved_response"},
                 {:before_claim, "validate_response", "saved_response"}
               ]
             )

    constructors =
      for {index, _, [state]} <- calls(events, CoreSegment, :advance),
          state["machine"]["stack"] == [%{"op" => "construct"}],
          do: index

    assert constructors != []
    assert Enum.all?(constructors, &(claim_ack < &1))
    assert claim_ack < commit_call(events, 6)
    [{request_call, _, _}] = calls(events, CallerBackend, :request)
    [{effect_call, _, _}] = calls(events, Effect, :run)
    assert claim_ack < request_call
    assert claim_ack < effect_call
    assert fixture.identity.incarnation == 2
  end

  defp assert_schema_retirement(fixture, outcome, events, owner) do
    retirement = outcome.retirement
    assert retirement.release == :confirmed
    assert retirement.broker == :terminated
    assert retirement.resource_handle.kind == :workflow_schema
    assert retirement.resource_handle.owner_id == fixture.binding.owner_id
    assert retirement.resource_handle.incarnation == fixture.binding.incarnation
    assert retirement.helper.cleanup_confirmed
    assert retirement.helper.exit_status == 0
    assert is_integer(retirement.helper.os_pid)
    refute File.exists?("/proc/#{retirement.helper.os_pid}")
    registry = fixture.binding.resource_registry

    [{register_call, register_pid, [^registry, _, :workflow_schema, broker, options]}] =
      calls(events, ResourceRegistry, :register)
      |> Enum.filter(fn {_, _, [_, _, kind, _, _]} -> kind == :workflow_schema end)

    assert options[:owner_pid] == owner
    assert options[:incarnation] == fixture.binding.incarnation

    {register_ack, {:ok, handle}} =
      returned(events, register_call, register_pid, {ResourceRegistry, :register, 5})

    assert handle === retirement.resource_handle
    [{_, _, [helper_options]}] = calls(events, PortSession, :start_link)
    assert helper_options[:owner_pid] == owner
    assert helper_options[:node_executable] == @node

    assert helper_options[:helper_path] ==
             Path.join(@root, "packages/tool-host/src/workflow/schema-stdio.mjs")

    refute Process.alive?(broker)

    for {index, pid, [^broker, request, _, _]} <- calls(events, PortSession, :fulfill) do
      assert register_ack < index
      {_, {:ok, receipt}} = returned(events, index, pid, {PortSession, :fulfill, 4})

      assert receipt === %{
               "type" => "result",
               "id" => request["id"],
               "result" => "ok",
               "outcome" =>
                 if(request["kind"] == "compile_schema", do: "compiled", else: "valid"),
               "cacheEntries" => 1
             }
    end

    [{close_call, close_pid, [^broker]}] = calls(events, PortSession, :close)
    {close_ack, {:ok, status}} = returned(events, close_call, close_pid, {PortSession, :close, 1})
    assert status === retirement.helper

    {release_call, release_pid, [^registry, ^handle, owner_id]} =
      one_call(events, ResourceRegistry, :release, fn [_, h, _] -> h == handle end)

    assert close_ack < release_call
    {_, {:ok, :ok}} = returned(events, release_call, release_pid, {ResourceRegistry, :release, 3})

    assert {:ok, %{status: :confirmed}} =
             ResourceRegistry.cleanup_status(registry, handle, owner_id)
  end

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

  defp assert_ordered_root(machine, raw, keys) do
    matches =
      for {id, %{"type" => "object", "keys" => ^keys}} <- machine["heap"]["nodes"],
          do: %{"type" => "reference", "id" => id}

    assert Enum.any?(matches, &(JSON.stringify(&1, machine["heap"]) === {:ok, raw}))
  end

  defp assert_root_receipt(fixture, operation, envelope) do
    assert {:ok, aggregate} = Store.load(fixture.store, fixture.identity.run_id)
    assert aggregate.run.state == :completed
    assert aggregate.incarnation == fixture.identity.incarnation
    assert aggregate.run.execution_intents["tool:#{operation.invocation_id}"].status == :consumed

    assert aggregate.run.tool_results[operation.invocation_id] === %{
             value: envelope,
             is_error: false
           }

    assert aggregate.run.context.conversation.headless_result.value === envelope
    assert Map.get(aggregate.run, :provider_attempts, %{}) == %{}
    aggregate
  end

  defp open_root(root, files, session_id, agent, store, action, path) do
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
        expected: %{
          target: %{tool_name: "synapsis::read", tool_revision: 1, arguments: %{"path" => path}},
          first_json: @first,
          second_json: @second
        },
        workflow_effect_registration: registration,
        session_binding: binding,
        profiles_context: profiles_context,
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

    %{supervisor: task_supervisor} = :sys.get_state(parent)

    for pid <- [parent, session, binding.resource_registry, supervisor, task_supervisor],
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

    assert_receive {:driver_outcome, owner, operation, adapters, {:ok, outcome}, before_parent,
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

    assert Enum.sort(Map.keys(adapters)) == [:request, :response_json]
    assert is_function(adapters.request, 2)
    assert is_function(adapters.response_json, 1)
    {outcome, events, owner, operation, adapters}
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
    targets =
      @trace_targets ++
        [
          {CallerBackend, :adapters, 2},
          {CallerBackend, :request, 4},
          {CallerBackend, :response_json, 3}
        ]

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
      10_000 -> flunk("ordinary admitted effect driver caller did not exit normally")
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

  defp adapter_calls(events, name, predicate),
    do:
      for(
        {:adapter_call, message, owner, result, state} <- events,
        elem(message, 0) == name and predicate.(message),
        do: {message, owner, result, state}
      )

  defp commit_revisions(events),
    do:
      for(
        {_, _, {:ok, record}} <- returns(events, Continuations, :commit, 5),
        do: record.revision
      )

  defp commit_call(events, revision) do
    {index, _, _} =
      one_call(events, Continuations, :commit, fn [_, _, expected, _, _] ->
        expected == revision
      end)

    index
  end

  defp schema_requests(events),
    do:
      for(
        {_, _, [_, request, _, _]} <- calls(events, PortSession, :fulfill),
        do: [request["kind"], request["boundary"]]
      )

  defp ordered_complete_envelope do
    ~S"""
    {
      "ok": true,
      "status": "ok",
      "output": [
        {
          "details": {
            "content": "second\n",
            "kind": "text"
          },
          "content": [
            {
              "text": "second\n",
              "type": "text"
            }
          ]
        }
      ],
      "requiresApproval": null
    }
    """
    |> String.trim_trailing("\n")
  end

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

  defp digest(arguments),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(arguments, [:deterministic]))
end
