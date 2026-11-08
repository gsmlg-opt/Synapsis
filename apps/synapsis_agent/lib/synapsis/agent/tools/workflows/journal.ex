defmodule Synapsis.Agent.Tools.Workflows.Journal do
  @moduledoc """
  Acknowledged workflow effect occurrences in one durable continuation.

  This trusted internal API runs in the caller's admitted native effect task.
  Only an acknowledged new pending CAS reaches Effect.run/2. Full successful
  native evidence is retained unchanged in an immutable runtime fact before the
  settled CAS. Reopen is read-only; pending or uncertain evidence never dispatches.
  Explicit segment APIs retain the waiting v2 Machine through settlement, then
  acknowledge its semantic result import and consumed cursor in one further CAS.
  Opt-in v3 state operations retain actual Local/helper evidence in separate
  immutable facts and publish their one observed ACK before durable consumption.
  Standalone v1 journal APIs retain their original exact-latest revision rules.
  """

  alias Backplane.AgentRuntime.Codex.{ResourceRegistry, Session}
  alias Synapsis.Agent.Tools.Filesystem
  alias Synapsis.Agent.Tools.Workflows.Effect
  alias Synapsis.Runtime.Store
  alias Synapsis.Filesystem.Local
  alias Synapsis.Workflow.{Continuations, Live, State}
  alias Synapsis.Workflow.Schema.PortSession
  alias Synapsis.Workflow.Journal, as: CoreJournal
  alias Synapsis.Workflow.Segment, as: CoreSegment

  @source "// @exec: {\"yield_time_ms\": 1000}\nreturn await tools[input.tool_name](input.arguments);\n"
  @scope ~w(run_id incarnation catalog_revision)a

  def create(context) do
    with {:ok, agent_id} <- identity(context, nil) do
      step(:pending_commit, nil, 1, fn ->
        with {:ok, deadline} <- live_deadline(context) do
          Continuations.create(context.session_id, agent_id, CoreJournal.new(),
            deadline: deadline
          )
        end
      end)
    end
  end

  def run(record, request, context) do
    with {:ok, agent_id} <- identity(context, record),
         {:ok, loaded} <-
           step(:load, record, nil, fn ->
             with :ok <- ensure(is_map(record), :invalid_continuation_record),
                  {:ok, loaded} <-
                    read_io(fn -> live_deadline(context) end, fn deadline ->
                      Continuations.load(context.session_id, record.id, deadline: deadline)
                    end),
                  :ok <- ensure(loaded === record, :resource_conflict),
                  {:ok, _} <-
                    inspect_record(loaded, context.session_id, agent_id, loaded.revision),
                  {:ok, _} <- inspect_entries(loaded, fn -> live_deadline(context) end) do
               {:ok, loaded}
             end
           end),
         {:ok, snapshot} <-
           step(:prepare, loaded, nil, fn ->
             with {:ok, encoded} <- CoreJournal.encode_request(request),
                  :ok <- ensure(request.correlation.workflow_id === loaded.id, :workflow_mismatch) do
               CoreJournal.prepare(loaded.snapshot, loaded.revision + 1, encoded, origin(context))
             end
           end) do
      # No loaded pending record, retained fact or caller token can enter this
      # dispatch branch: it is reached only by this call's actual CAS ACK.
      case step(:pending_commit, loaded, loaded.revision + 1, fn ->
             with {:ok, deadline} <- live_deadline(context) do
               Continuations.commit(loaded.session_id, loaded.id, loaded.revision, snapshot,
                 deadline: deadline
               )
             end
           end) do
        {:ok, pending} -> execute_pending(pending, request, context)
        error -> error
      end
    end
  end

  @doc "Acknowledges a real awaiting v2 Machine before entering the existing native Effect."
  def run_segment(record, awaiting_snapshot, request, context) do
    with {:ok, agent_id} <- identity(context, record),
         {:ok, %{record: loaded}} <- load_segment(record, agent_id, context),
         {:ok, snapshot} <-
           step(:prepare, loaded, nil, fn ->
             with {:ok, encoded} <- CoreJournal.encode_request(request),
                  :ok <-
                    ensure(request.correlation.workflow_id === loaded.id, :workflow_mismatch),
                  :ok <- ensure(is_map(awaiting_snapshot), :invalid_segment_snapshot),
                  :ok <-
                    ensure(
                      Map.delete(awaiting_snapshot, "machine") ===
                        Map.delete(loaded.snapshot, "machine"),
                      :resource_conflict
                    ) do
               # Pure progress may be newer than the acknowledged Machine. The
               # actual record remains untouched until this pending CAS ACK.
               CoreSegment.prepare_effect(
                 awaiting_snapshot,
                 loaded.revision + 1,
                 encoded,
                 origin(context)
               )
             end
           end) do
      case step(:pending_commit, loaded, loaded.revision + 1, fn ->
             with {:ok, deadline} <- live_deadline(context) do
               Continuations.commit(loaded.session_id, loaded.id, loaded.revision, snapshot,
                 deadline: deadline
               )
             end
           end) do
        {:ok, pending} -> execute_pending(pending, request, context)
        error -> error
      end
    end
  end

  @doc "Dispatches one newly acknowledged state operation and retains all three CAS acknowledgements."
  def run_state_segment(
        record,
        awaiting_snapshot,
        live_binding,
        context,
        %{broker: broker} = options
      )
      when map_size(options) == 1 do
    with {:ok, agent_id} <- identity(context, record),
         {:ok, loaded} <-
           step(:load, record, nil, fn ->
             with {:ok, loaded} <-
                    read_io(fn -> live_deadline(context) end, fn deadline ->
                      Continuations.load(context.session_id, record.id, deadline: deadline)
                    end),
                  :ok <- ensure(loaded === record, :resource_conflict),
                  {:ok, _} <-
                    inspect_segment_record(loaded, context.session_id, agent_id, record.revision),
                  :ok <- ensure(loaded.snapshot["version"] === 3, :invalid_segment_snapshot),
                  :ok <-
                    ensure(
                      Map.delete(awaiting_snapshot, "machine") ===
                        Map.delete(loaded.snapshot, "machine"),
                      :resource_conflict
                    ) do
               {:ok, loaded}
             end
           end),
         {:ok, %{request: request, helpers: helpers}} <-
           step(:state_path, loaded, nil, fn ->
             state_request(loaded, awaiting_snapshot, broker, context)
           end),
         {:ok, snapshot} <-
           step(:prepare, loaded, nil, fn ->
             CoreSegment.prepare_operation(
               awaiting_snapshot,
               loaded.revision + 1,
               :state_operation,
               request,
               origin(context)
             )
           end),
         {:ok, pending} <- state_commit(loaded, snapshot, context, :pending_commit) do
      step(:state_operation, pending, nil, fn ->
        execute_state_pending(pending, live_binding, broker, helpers, context)
      end)
    end
  end

  defp state_request(record, snapshot, broker, context) do
    machine = snapshot["machine"]
    semantic = machine["pending_request"]
    scope = snapshot["source"]["state_scope"]

    helper = %{
      "id" => semantic["id"],
      "kind" => "state_key_path",
      "key" => semantic["key"],
      "state_dir" => scope["state_dir"]
    }

    with {:ok, timeout} <- state_timeout(context),
         {:ok, receipt} <- PortSession.fulfill(broker, helper, machine["heap"], timeout),
         %{"id" => id, "result" => "ok", "outcome" => "state_path", "lexical_path" => lexical} <-
           receipt,
         true <- id === semantic["id"] and is_binary(lexical),
         absolute = Path.expand(lexical, scope["process_cwd"]),
         {:ok, root, _} <- Local.resolve(context[:project_root], "."),
         :ok <- ensure(root === scope["project_root"], :scope_mismatch),
         {:ok, absolute, relative} <- Local.resolve(root, absolute),
         {:ok, request} <-
           CoreJournal.encode_state_request(%{
             correlation: %{workflow_id: record.id, request_id: id, segment: machine["segment"]},
             semantic: semantic,
             scope: scope,
             target: %{lexical_path: lexical, absolute_path: absolute, relative_path: relative}
           }) do
      {:ok, %{request: request, helpers: [%{request: helper, receipt: receipt}]}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_state_path_receipt}
    end
  end

  defp execute_state_pending(pending, binding, broker, helpers, context) do
    entry = List.last(effect_entries(pending.snapshot))

    reference = %{
      "kind" => "workflow_state_receipt",
      "version" => 1,
      "fact_id" => pending.id <> ":state:" <> Integer.to_string(pending.revision),
      "namespace" => entry["origin"]["namespace"],
      "incarnation" => entry["origin"]["store_incarnation"]
    }

    with {:ok, settled_snapshot} <-
           step(:settle_candidate, pending, pending.revision + 1, fn ->
             CoreSegment.settle_operation(
               pending.snapshot,
               pending.revision,
               pending.revision + 1,
               reference
             )
           end),
         {:ok, io} <- state_io(pending, settled_snapshot, binding, broker, helpers, context),
         candidate = io.candidate,
         {:ok, _} <-
           step(:receipt_fact, pending, nil, fn ->
             fact = %{
               version: 1,
               workflow_id: pending.id,
               agent_id: pending.agent_id,
               pending_revision: pending.revision,
               request: entry["request"],
               origin: entry["origin"],
               result: %{
                 ack: candidate.ack,
                 capture: candidate.capture,
                 write_bytes: state_write_bytes(entry["request"]["semantic"]),
                 local: Map.drop(io.local, [:value]),
                 helper_receipts: candidate.helper_receipts
               },
               retirement: io.retirement
             }

             with :ok <- verify_state_fact(pending, entry, fact, reference),
                  {:ok, _} <- live_deadline(context),
                  :ok <-
                    Store.put_fact(
                      pending.session_id,
                      :workflow_state_receipt,
                      reference["fact_id"],
                      fact
                    ),
                  do: {:ok, reference}
           end),
         {:ok, settled} <- state_commit(pending, settled_snapshot, context, :settled_commit) do
      # Keep the actual waiting-settled ACK even if the final commit is uncertain.
      with {:ok, _} <-
             step(:settled_candidate, settled, nil, fn ->
               with :ok <- ensure(settled.snapshot === settled_snapshot, :resource_conflict),
                    do: {:ok, :equal}
             end),
           {:ok, consumed} <-
             state_commit(settled, candidate.consumed_snapshot, context, :consumed_commit) do
        {:ok, %{record: consumed, binding: candidate.binding}}
      end
    end
  end

  defp state_io(pending, settled, binding, broker, helpers, context) do
    entry = List.last(effect_entries(pending.snapshot))
    request = entry["request"]

    with {:ok, ticket} <-
           step(:state_start, pending, nil, fn ->
             with {:ok, deadline} <- live_deadline(context) do
               Local.start_state_operation(
                 request["scope"]["project_root"],
                 request["target"]["absolute_path"],
                 deadline: deadline,
                 owner_pid: self()
               )
             end
           end) do
      guardian = Local.state_operation_owner(ticket)
      session = context.session_binding

      registered =
        step(:state_register, pending, nil, fn ->
          ResourceRegistry.register(
            session.resource_registry,
            session.owner_id,
            :workflow_state_io,
            guardian,
            incarnation: session.incarnation,
            owner_pid: self(),
            cleanup: fn -> Local.close_state_operation(ticket) end
          )
        end)

      case registered do
        {:ok, handle} ->
          result =
            step(:state_io, pending, nil, fn ->
              with {:ok, ^guardian} <-
                     ResourceRegistry.fetch(session.resource_registry, handle, session.owner_id),
                   {:ok, _} <- live_deadline(context),
                   {:ok, local} <-
                     Local.run_state_operation(
                       ticket,
                       state_local_request(settled, binding, broker, helpers, context)
                     ) do
                {:ok, local}
              end
            end)

          acknowledged =
            with {:ok, local} <- result,
                 {:ok, candidate} <-
                   step(:state_ack, pending, pending.revision + 2, fn ->
                     case request["semantic"]["kind"] do
                       "state_get" ->
                         {:ok, local.value}

                       "state_set" ->
                         state_candidate(
                           settled,
                           binding,
                           %{
                             ack: %{
                               "id" => request["semantic"]["id"],
                               "kind" => "state_set",
                               "result" => "ok"
                             },
                             capture: :not_captured,
                             helper_receipts: helpers
                           },
                           context
                         )

                       _ ->
                         state_candidate(settled, binding, local.value, context)
                     end
                   end) do
              {:ok, %{local: local, candidate: candidate}}
            end

          retirement =
            step(:state_retirement, pending, nil, fn ->
              with {:ok, :ok} <-
                     ResourceRegistry.release(session.resource_registry, handle, session.owner_id),
                   {:ok, %{status: :confirmed}} <-
                     ResourceRegistry.cleanup_status(
                       session.resource_registry,
                       handle,
                       session.owner_id
                     ),
                   :ok <- ensure(not Process.alive?(guardian), :state_cleanup_unconfirmed) do
                {:ok, %{resource_handle: handle, release: :confirmed, guardian: :normal}}
              else
                _ -> {:error, :state_cleanup_unconfirmed}
              end
            end)

          case retirement do
            {:ok, evidence} ->
              with {:ok, acknowledged} <- acknowledged do
                {:ok, Map.put(acknowledged, :retirement, evidence)}
              end

            {:error, problem} ->
              {:error, Map.put(problem, :quiescent, false)}
          end

        error ->
          case Local.close_state_operation(ticket) do
            :ok ->
              error

            _ ->
              {:error,
               %{
                 stage: :state_retirement,
                 reason: :state_cleanup_unconfirmed,
                 record: pending,
                 attempted_revision: nil,
                 quiescent: false
               }}
          end
      end
    end
  end

  defp state_local_request(settled, binding, broker, helpers, context) do
    semantic = settled["machine"]["pending_request"]

    case semantic["kind"] do
      "state_get" ->
        {:read_locked,
         fn capture ->
           with {:ok, plan} <-
                  state_capture(
                    capture,
                    semantic,
                    settled["machine"]["heap"],
                    broker,
                    helpers,
                    context
                  ),
                ack = %{
                  "id" => semantic["id"],
                  "kind" => "state_get",
                  "result" => "ok",
                  "text" => plan.capture.text
                } do
             state_candidate(settled, binding, Map.put(plan, :ack, ack), context)
           end
         end}

      "state_set" ->
        {:write_always, semantic["text"]}

      "state_diff" ->
        {:transition_locked,
         fn capture ->
           with {:ok, plan} <-
                  state_capture(
                    capture,
                    semantic,
                    settled["machine"]["heap"],
                    broker,
                    helpers,
                    context
                  ),
                {:ok, before, changed, heap} <-
                  State.diff(plan.capture.text, semantic["value"], settled["machine"]["heap"]),
                {:ok, rollback} <- state_rollback(capture, before, heap) do
             ack = %{
               "id" => semantic["id"],
               "kind" => "state_diff",
               "result" => "ok",
               "before_text" => plan.capture.text,
               "changed" => changed
             }

             {:ok,
              %{write: semantic["text"], rollback: rollback, value: Map.put(plan, :ack, ack)}}
           end
         end}
    end
  end

  defp state_capture(%{exists: false, bytes: nil}, _semantic, _heap, _broker, helpers, _context),
    do: {:ok, %{capture: %{exists: false, bytes: nil, text: nil}, helper_receipts: helpers}}

  defp state_capture(%{exists: true, bytes: bytes}, semantic, heap, broker, helpers, context) do
    request = %{
      "id" => semantic["id"],
      "kind" => "decode_state_text",
      "bytes_base64" => Base.encode64(bytes)
    }

    with {:ok, timeout} <- state_timeout(context),
         {:ok,
          %{
            "id" => id,
            "result" => "ok",
            "outcome" => "decoded",
            "value" => %{"type" => "string", "value" => text}
          } = receipt} <- PortSession.fulfill(broker, request, heap, timeout),
         true <- id === semantic["id"] do
      {:ok,
       %{
         capture: %{exists: true, bytes: bytes, text: text},
         helper_receipts: helpers ++ [%{request: request, receipt: receipt}]
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_state_decode_receipt}
    end
  end

  defp state_rollback(%{exists: false}, _before, _heap), do: {:ok, :remove}

  defp state_rollback(%{exists: true}, before, heap) do
    with {:ok, bytes} <- State.text(before, heap), do: {:ok, {:replace, bytes}}
  end

  defp state_candidate(settled, binding, plan, context) do
    entry = List.last(settled["journal"]["operations"])

    source_context = %{
      request_id: entry["request"]["semantic"]["id"],
      lexical_path: entry["request"]["target"]["lexical_path"]
    }

    with {{:ok, consumed}, observations} <-
           CoreSegment.consume_operation_observed(settled, settled["revision"] + 1, plan.ack),
         {:ok, timeout} <- state_timeout(context),
         {:ok, {:continue, _}, next_binding} <-
           Live.publish_observed(
             binding,
             settled["machine"],
             {{:continue, consumed["machine"]}, observations},
             source_context,
             timeout
           ) do
      {:ok, Map.merge(plan, %{consumed_snapshot: consumed, binding: next_binding})}
    else
      {{:error, reason}, _} -> {:error, reason}
      {:error, _} = error -> error
      _ -> {:error, :invalid_state_transition}
    end
  end

  defp state_write_bytes(%{"kind" => "state_get"}), do: nil
  defp state_write_bytes(semantic), do: semantic["text"]

  defp state_timeout(context) do
    with {:ok, deadline} <- live_deadline(context),
         timeout = min(120_000, deadline - now()),
         :ok <- ensure(timeout > 0, :timeout),
         do: {:ok, timeout}
  end

  defp state_commit(record, snapshot, context, stage) do
    step(stage, record, record.revision + 1, fn ->
      with {:ok, deadline} <- live_deadline(context) do
        Continuations.commit(record.session_id, record.id, record.revision, snapshot,
          deadline: deadline
        )
      end
    end)
  end

  @doc "Verifies immutable native success and acknowledges semantic consumption in one CAS."
  def consume_segment(record, response_json, context) do
    with {:ok, agent_id} <- identity(context, record),
         {:ok, %{record: loaded, entries: entries}} <- load_segment(record, agent_id, context),
         {:ok, %{snapshot: snapshot, effect: effect}} <-
           step(:consume, loaded, nil, fn ->
             with {:ok, %{consumed_effects: consumed}} <-
                    CoreSegment.inspect_snapshot(loaded.snapshot),
                  [%{state: :settled, entry: entry, effect: effect}] <-
                    Enum.drop(entries, consumed),
                  {:ok, value} <- Jason.decode(response_json),
                  :ok <- ensure(value === effect.consumer_value, :invalid_effect_consumer_value),
                  {:ok, snapshot} <-
                    CoreSegment.consume_effect(
                      loaded.snapshot,
                      loaded.revision + 1,
                      entry["request"]["correlation"]["request_id"],
                      response_json
                    ) do
               # The trusted caller supplies source order explicitly. Never
               # encode the verified unordered native map as ordered Value JSON.
               {:ok, %{snapshot: snapshot, effect: effect}}
             else
               {:error, _} = error -> error
               _ -> {:error, :invalid_segment_transition}
             end
           end),
         {:ok, consumed} <-
           step(:consumed_commit, loaded, loaded.revision + 1, fn ->
             with {:ok, deadline} <- live_deadline(context) do
               Continuations.commit(loaded.session_id, loaded.id, loaded.revision, snapshot,
                 deadline: deadline
               )
             end
           end) do
      {:ok, %{record: consumed, effect: effect}}
    end
  end

  def reopen(session_id, agent_id, workflow_id, expected_revision, opts) do
    with {:ok, deadline} <-
           step(:reopen, nil, nil, fn ->
             with :ok <-
                    ensure(
                      uuid?(session_id) and uuid?(agent_id) and uuid?(workflow_id),
                      :invalid_scope
                    ),
                  :ok <- ensure(positive?(expected_revision), :invalid_revision),
                  [deadline: deadline] when is_integer(deadline) <- opts,
                  {:ok, _} <- fixed_deadline(deadline) do
               {:ok, deadline}
             else
               {:error, _} = error -> error
               _ -> {:error, :invalid_options}
             end
           end),
         {:ok, record} <-
           step(:reopen, nil, nil, fn ->
             read_io(fn -> fixed_deadline(deadline) end, fn current_deadline ->
               Continuations.load(session_id, workflow_id, deadline: current_deadline)
             end)
           end),
         {:ok, entries} <-
           step(:reopen, record, nil, fn ->
             with {:ok, _} <- inspect_record(record, session_id, agent_id, expected_revision) do
               inspect_entries(record, fn -> fixed_deadline(deadline) end)
             end
           end) do
      {:ok, %{record: record, entries: entries}}
    end
  end

  @doc "Reads and verifies a v2/v3 aggregate and all retained facts without dispatch or writes."
  def reopen_segment(session_id, agent_id, workflow_id, expected_revision, opts) do
    with {:ok, deadline} <-
           step(:reopen, nil, nil, fn ->
             with :ok <-
                    ensure(
                      uuid?(session_id) and uuid?(agent_id) and uuid?(workflow_id),
                      :invalid_scope
                    ),
                  :ok <- ensure(positive?(expected_revision), :invalid_revision),
                  [deadline: deadline] when is_integer(deadline) <- opts,
                  {:ok, _} <- fixed_deadline(deadline) do
               {:ok, deadline}
             else
               {:error, _} = error -> error
               _ -> {:error, :invalid_options}
             end
           end),
         {:ok, record} <-
           step(:reopen, nil, nil, fn ->
             read_io(fn -> fixed_deadline(deadline) end, fn current_deadline ->
               Continuations.load(session_id, workflow_id, deadline: current_deadline)
             end)
           end),
         {:ok, entries} <-
           step(:reopen, record, nil, fn ->
             with {:ok, _} <-
                    inspect_segment_record(record, session_id, agent_id, expected_revision) do
               inspect_entries(record, fn -> fixed_deadline(deadline) end)
             end
           end) do
      {:ok, %{record: record, entries: entries}}
    end
  end

  defp load_segment(record, agent_id, context) do
    step(:load, record, nil, fn ->
      with :ok <- ensure(is_map(record), :invalid_continuation_record),
           {:ok, loaded} <-
             read_io(fn -> live_deadline(context) end, fn deadline ->
               Continuations.load(context.session_id, record.id, deadline: deadline)
             end),
           :ok <- ensure(loaded === record, :resource_conflict),
           {:ok, _} <-
             inspect_segment_record(loaded, context.session_id, agent_id, loaded.revision),
           {:ok, entries} <- inspect_entries(loaded, fn -> live_deadline(context) end) do
        {:ok, %{record: loaded, entries: entries}}
      end
    end)
  end

  defp execute_pending(pending, request, context) do
    deadline = fn -> live_deadline(context) end

    with {:ok, effect} <-
           step(:effect, pending, nil, fn ->
             with {:ok, _} <- deadline.() do
               Effect.run(request, context)
             end
           end),
         {:ok, reference} <-
           step(:receipt_fact, pending, nil, fn ->
             entry = List.last(effect_entries(pending.snapshot))

             with :ok <- ensure(is_map(effect), :invalid_effect_evidence),
                  reference = reference(pending, effect),
                  :ok <- verify_effect(pending, entry, effect, reference, deadline),
                  {:ok, _} <- deadline.(),
                  :ok <-
                    Store.put_fact(
                      pending.session_id,
                      :workflow_effect_receipt,
                      reference["fact_id"],
                      %{
                        version: 1,
                        workflow_id: pending.id,
                        agent_id: pending.agent_id,
                        pending_revision: pending.revision,
                        effect: effect
                      }
                    ) do
               {:ok, reference}
             end
           end),
         {:ok, settled} <-
           step(:settled_commit, pending, pending.revision + 1, fn ->
             with {:ok, snapshot} <-
                    settle_snapshot(pending.snapshot, pending.revision, reference),
                  {:ok, deadline} <- deadline.() do
               # A known successful CAS remains acknowledged even if it is late.
               Continuations.commit(pending.session_id, pending.id, pending.revision, snapshot,
                 deadline: deadline
               )
             end
           end) do
      {:ok, %{record: settled, effect: effect}}
    end
  end

  defp settle_snapshot(%{"kind" => "workflow", "version" => 1} = snapshot, revision, reference),
    do: CoreJournal.settle(snapshot, revision, revision + 1, reference)

  defp settle_snapshot(
         %{"kind" => "workflow_segment", "version" => 2} = snapshot,
         revision,
         reference
       ),
       do: CoreSegment.settle_effect(snapshot, revision, revision + 1, reference)

  defp effect_entries(%{"kind" => "workflow", "version" => 1, "effects" => entries}), do: entries

  defp effect_entries(%{"kind" => "workflow_segment", "version" => 2, "journal" => journal}),
    do: journal["effects"]

  defp effect_entries(%{"kind" => "workflow_segment", "version" => 3, "journal" => journal}),
    do: journal["operations"]

  defp identity(context, record) do
    step(:identity, record, nil, fn ->
      with %{
             profiles_context: %{session: %{id: session_id}, agent: %{id: agent_id, name: name}},
             profiles_snapshot: %{scope: scope},
             session_id: session_id,
             caller: caller,
             operation: operation,
             session_binding: binding,
             store: %{namespace: namespace, incarnation: incarnation}
           } <- context,
           :ok <-
             ensure(uuid?(session_id) and uuid?(agent_id) and nonempty?(name), :invalid_identity),
           :ok <-
             ensure(is_map(operation) and is_map(binding) and is_map(scope), :invalid_context),
           :ok <-
             ensure(
               nonempty?(namespace) and positive?(incarnation) and nonempty?(caller),
               :invalid_context
             ),
           :ok <-
             ensure(
               scope[:session_id] === session_id and scope[:caller] === caller and
                 operation[:caller] === caller,
               :scope_mismatch
             ),
           :ok <-
             ensure(
               Enum.all?(
                 @scope,
                 &(Map.has_key?(scope, &1) and Map.has_key?(operation, &1) and
                     scope[&1] === operation[&1])
               ),
               :scope_mismatch
             ),
           {:ok, saved} <-
             read_io(fn -> live_deadline(context) end, fn _deadline ->
               {:ok, Synapsis.AgentConfigs.get(agent_id)}
             end),
           :ok <-
             ensure(
               match?(%Synapsis.AgentConfig{id: ^agent_id, name: ^name, enabled: true}, saved),
               :invalid_identity
             ),
           {:ok, _} <-
             read_io(fn -> live_deadline(context) end, fn _deadline ->
               Session.validate(binding, operation)
             end) do
        {:ok, agent_id}
      else
        {:error, _} = error -> error
        _ -> {:error, :invalid_context}
      end
    end)
  end

  defp origin(context) do
    %{
      "namespace" => context.store.namespace,
      "store_incarnation" => context.store.incarnation,
      "parent_run_id" => context.operation.run_id,
      "parent_incarnation" => context.operation.incarnation,
      "parent_invocation_id" => context.operation.invocation_id,
      "caller" => context.operation.caller,
      "resource_owner_id" => context.session_binding.owner_id,
      "resource_incarnation" => context.session_binding.incarnation
    }
  end

  defp inspect_record(record, session_id, agent_id, expected_revision) do
    with :ok <- inspect_record_scope(record, session_id, agent_id, expected_revision),
         {:ok, entries} <- CoreJournal.inspect_snapshot(record.snapshot),
         latest =
           (case List.last(entries) do
              nil -> 1
              %{"state" => "pending", "pending_revision" => revision} -> revision
              %{"state" => "settled", "settled_revision" => revision} -> revision
            end),
         :ok <- ensure(record.revision === latest, :invalid_journal_revision),
         :ok <- inspect_workflow(entries, record.id) do
      {:ok, entries}
    end
  end

  defp inspect_segment_record(record, session_id, agent_id, expected_revision) do
    with :ok <- inspect_record_scope(record, session_id, agent_id, expected_revision),
         {:ok, _} <- CoreSegment.inspect_snapshot(record.snapshot),
         :ok <-
           ensure(record.snapshot["revision"] === record.revision, :invalid_segment_revision),
         entries = effect_entries(record.snapshot),
         :ok <- inspect_workflow(entries, record.id) do
      {:ok, entries}
    end
  end

  defp inspect_record_scope(record, session_id, agent_id, expected_revision) do
    with :ok <-
           ensure(
             keys?(
               record,
               ~w(schema_version id session_id agent_id revision inserted_at updated_at snapshot)a
             ),
             :invalid_continuation_record
           ),
         :ok <-
           ensure(record.schema_version === 1 and uuid?(record.id), :invalid_continuation_record),
         :ok <-
           ensure(
             record.session_id === session_id and record.agent_id === agent_id,
             :scope_mismatch
           ),
         :ok <- ensure(record.revision === expected_revision, :resource_conflict) do
      :ok
    end
  end

  defp inspect_workflow(entries, workflow_id),
    do:
      ensure(
        Enum.all?(entries, &(&1["request"]["correlation"]["workflow_id"] === workflow_id)),
        :workflow_mismatch
      )

  defp inspect_entries(record, deadline) do
    Enum.reduce_while(effect_entries(record.snapshot), {:ok, []}, fn entry, {:ok, entries} ->
      case inspect_entry(record, entry, deadline) do
        {:ok, inspected} -> {:cont, {:ok, [inspected | entries]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp inspect_entry(_record, %{"state" => "pending"} = entry, _deadline),
    do: {:ok, %{state: :pending, entry: entry}}

  defp inspect_entry(
         record,
         %{"type" => "state_operation", "state" => "settled"} = entry,
         deadline
       ) do
    reference = entry["receipt"]

    with {:ok, fact} <-
           read_io(deadline, fn _ ->
             Store.get_fact(record.session_id, :workflow_state_receipt, reference["fact_id"])
           end),
         :ok <- verify_state_fact(record, entry, fact, reference) do
      {:ok, %{state: :settled, entry: entry, fact: fact}}
    end
  end

  defp inspect_entry(record, %{"state" => "settled"} = entry, deadline) do
    reference = entry["receipt"]

    with {:ok, fact} <-
           read_io(deadline, fn _deadline ->
             Store.get_fact(record.session_id, :workflow_effect_receipt, reference["fact_id"])
           end),
         :ok <-
           ensure(
             keys?(fact, ~w(version workflow_id agent_id pending_revision effect)a),
             :invalid_receipt_fact
           ),
         :ok <-
           ensure(
             fact.version === 1 and fact.workflow_id === record.id and
               fact.agent_id === record.agent_id and
               fact.pending_revision === entry["pending_revision"],
             :invalid_receipt_fact
           ),
         :ok <- verify_effect(record, entry, fact.effect, reference, deadline) do
      {:ok, %{state: :settled, entry: entry, effect: fact.effect}}
    end
  end

  defp reference(record, effect) do
    %{
      "kind" => "workflow_effect_receipt",
      "fact_id" => record.id <> ":" <> Integer.to_string(record.revision),
      "namespace" => effect.locator.namespace,
      "run_id" => effect.locator.run_id,
      "incarnation" => effect.locator.incarnation,
      "final_revision" => effect.receipt.final_revision
    }
  end

  defp verify_state_fact(record, entry, fact, reference) do
    with true <-
           keys?(
             fact,
             ~w(version workflow_id agent_id pending_revision request origin result retirement)a
           ),
         true <-
           fact.version === 1 and fact.workflow_id === record.id and
             fact.agent_id === record.agent_id and
             fact.pending_revision === entry["pending_revision"],
         true <- fact.request === entry["request"] and fact.origin === entry["origin"],
         {:ok, request} <- CoreJournal.decode_state_request(fact.request),
         true <- request.correlation.workflow_id === record.id,
         true <-
           reference === %{
             "kind" => "workflow_state_receipt",
             "version" => 1,
             "fact_id" => record.id <> ":state:" <> Integer.to_string(entry["pending_revision"]),
             "namespace" => fact.origin["namespace"],
             "incarnation" => fact.origin["store_incarnation"]
           },
         true <- keys?(fact.result, ~w(ack capture write_bytes local helper_receipts)a),
         true <- keys?(fact.retirement, ~w(resource_handle release guardian)a),
         retirement = fact.retirement,
         true <- retirement.release === :confirmed and retirement.guardian === :normal,
         handle = retirement.resource_handle,
         true <- keys?(handle, ~w(resource_id owner_id incarnation kind)a),
         true <-
           nonempty?(handle.resource_id) and handle.owner_id === fact.origin["resource_owner_id"] and
             handle.incarnation === fact.origin["resource_incarnation"] and
             handle.kind === :workflow_state_io,
         true <- state_result?(request, fact.result),
         true <- state_fact_value?(fact) do
      :ok
    else
      _ -> {:error, :invalid_state_receipt_fact}
    end
  end

  defp state_result?(request, result) do
    semantic = request.semantic
    local = result.local

    keys?(local, ~w(before publication file_sync directory_sync cleanup_confirmed)a) and
      local.cleanup_confirmed === true and state_directory_sync?(local.directory_sync) and
      result.write_bytes === state_write_bytes(semantic) and
      state_ack?(semantic, result) and state_helpers?(request, result)
  end

  defp state_ack?(%{"kind" => "state_set", "id" => id}, result) do
    result.capture === :not_captured and result.local.before === :not_captured and
      result.local.publication === :published and result.local.file_sync === :confirmed and
      result.ack === %{"id" => id, "kind" => "state_set", "result" => "ok"}
  end

  defp state_ack?(%{"kind" => kind, "id" => id}, result)
       when kind in ["state_get", "state_diff"] do
    capture = result.capture

    capture_valid? =
      keys?(capture, ~w(exists bytes text)a) and
        ((capture.exists === false and capture.bytes === nil and capture.text === nil) or
           (capture.exists === true and is_binary(capture.bytes) and is_binary(capture.text) and
              String.valid?(capture.text))) and
        result.local.before === Map.take(capture, [:exists, :bytes])

    capture_valid? and
      if kind == "state_get" do
        result.local.publication === :not_applicable and
          result.local.file_sync === :not_applicable and
          result.ack === %{"id" => id, "kind" => kind, "result" => "ok", "text" => capture.text}
      else
        keys?(result.ack, ~w(id kind result before_text changed)) and
          result.local.publication === :published and result.local.file_sync === :confirmed and
          result.ack["id"] === id and result.ack["kind"] === kind and
          result.ack["result"] === "ok" and
          result.ack["before_text"] === capture.text and is_boolean(result.ack["changed"])
      end
  end

  defp state_ack?(_, _), do: false

  defp state_helpers?(request, result) do
    semantic = request.semantic

    expected_path = %{
      "id" => semantic["id"],
      "kind" => "state_key_path",
      "key" => semantic["key"],
      "state_dir" => request.scope["state_dir"]
    }

    case result.helper_receipts do
      [%{request: ^expected_path, receipt: receipt} = pair | rest] ->
        keys?(pair, ~w(request receipt)a) and
          state_helper_receipt?(
            receipt,
            semantic["id"],
            ~w(type id result outcome lexical_path cacheEntries)
          ) and
          receipt["outcome"] === "state_path" and
          receipt["lexical_path"] === request.target.lexical_path and
          state_decoder_evidence?(rest, result.capture, semantic["id"], receipt["cacheEntries"])

      _ ->
        false
    end
  end

  defp state_decoder_evidence?([], :not_captured, _id, _cache), do: true
  defp state_decoder_evidence?([], %{exists: false, bytes: nil, text: nil}, _id, _cache), do: true

  defp state_decoder_evidence?(
         [%{request: request, receipt: receipt} = pair],
         %{exists: true, bytes: bytes, text: text},
         id,
         cache
       ) do
    keys?(pair, ~w(request receipt)a) and
      request === %{
        "id" => id,
        "kind" => "decode_state_text",
        "bytes_base64" => Base.encode64(bytes)
      } and
      state_helper_receipt?(receipt, id, ~w(type id result outcome value cacheEntries)) and
      receipt["outcome"] === "decoded" and
      receipt["value"] === %{"type" => "string", "value" => text} and
      receipt["cacheEntries"] === cache
  end

  defp state_decoder_evidence?(_, _, _, _), do: false

  defp state_helper_receipt?(receipt, id, fields) do
    keys?(receipt, fields) and receipt["type"] === "result" and receipt["id"] === id and
      receipt["result"] === "ok" and is_integer(receipt["cacheEntries"]) and
      receipt["cacheEntries"] in 0..256
  end

  defp state_directory_sync?(value) when value in [:not_applicable, :confirmed], do: true
  defp state_directory_sync?({:unsupported, reason}), do: is_atom(reason)
  defp state_directory_sync?(_), do: false

  defp state_fact_value?(value) when is_map(value) and not is_struct(value),
    do: Enum.all?(value, fn {key, item} -> state_fact_value?(key) and state_fact_value?(item) end)

  defp state_fact_value?([]), do: true
  defp state_fact_value?([head | tail]), do: state_fact_value?(head) and state_fact_value?(tail)
  defp state_fact_value?({:unsupported, reason}), do: is_atom(reason)

  defp state_fact_value?(value) when is_atom(value) or is_binary(value) or is_number(value),
    do: true

  defp state_fact_value?(_), do: false

  defp verify_effect(record, entry, effect, reference, deadline) do
    with :ok <-
           ensure(
             keys?(effect, ~w(request locator consumer_value receipt retirement)a),
             :invalid_effect_evidence
           ),
         {:ok, request} <- CoreJournal.decode_request(entry["request"]),
         :ok <-
           ensure(
             effect.request === request and request.correlation.workflow_id === record.id,
             :invalid_effect_evidence
           ),
         origin = entry["origin"],
         locator = effect.locator,
         :ok <- ensure(is_map(locator) and nonempty?(locator[:run_id]), :invalid_effect_evidence),
         :ok <-
           ensure(
             locator === %{
               version: 1,
               session_id: record.session_id,
               namespace: origin["namespace"],
               run_id: reference["run_id"],
               incarnation: origin["store_incarnation"],
               kind: :workflow_effect,
               name: nil,
               agent_id: nil,
               parent_run_id: origin["parent_run_id"],
               parent_incarnation: origin["parent_incarnation"],
               parent_invocation_id: origin["parent_invocation_id"],
               effect_request: request
             },
             :invalid_effect_evidence
           ),
         :ok <-
           ensure(
             reference === %{
               "kind" => "workflow_effect_receipt",
               "fact_id" => record.id <> ":" <> Integer.to_string(entry["pending_revision"]),
               "namespace" => locator.namespace,
               "run_id" => locator.run_id,
               "incarnation" => locator.incarnation,
               "final_revision" => effect.receipt.final_revision
             },
             :invalid_effect_evidence
           ),
         :ok <-
           ensure(
             retirement?(effect.retirement, origin) and native_value?(effect),
             :invalid_effect_evidence
           ),
         {:ok, aggregate} <-
           read_io(deadline, fn _deadline ->
             Store.load(reference["namespace"], reference["run_id"])
           end),
         :ok <- verify_aggregate(aggregate, effect, origin, reference) do
      :ok
    end
  end

  defp verify_aggregate(aggregate, effect, origin, reference) do
    receipt = effect.receipt
    locator = effect.locator
    request = effect.request

    with :ok <-
           ensure(
             keys?(
               receipt,
               ~w(version run_id incarnation turn_id catalog_revision catalog_digest outer_intent target_intent target_result target_presentation final_revision)a
             ),
             :invalid_native_receipt
           ),
         :ok <- ensure(is_map(aggregate) and is_map(aggregate[:run]), :invalid_native_aggregate),
         run = aggregate.run,
         :ok <-
           ensure(
             aggregate[:incarnation] === locator.incarnation and
               aggregate[:revision] === reference["final_revision"] and
               positive?(aggregate[:revision]),
             :invalid_native_aggregate
           ),
         :ok <-
           ensure(
             run[:expected_revision] === aggregate.revision and
               run[:incarnation] === locator.incarnation and run[:run_id] === locator.run_id,
             :invalid_native_aggregate
           ),
         :ok <-
           ensure(
             run[:state] === :completed and Map.get(run, :active_tools, %{}) === %{} and
               is_nil(run[:active_provider]) and is_nil(run[:active_wait]) and
               Map.get(run, :provider_attempts, %{}) === %{},
             :invalid_native_aggregate
           ),
         :ok <- ensure(run.context.execution_mode === :headless, :invalid_native_aggregate),
         result = run.context.conversation.headless_result,
         :ok <-
           ensure(
             result.status === :completed and result.nested_invocations === 1 and
               result.value === effect.consumer_value,
             :invalid_native_aggregate
           ),
         intents = run.execution_intents,
         {:ok, outer} <-
           Map.fetch(intents, "tool:" <> receipt.outer_intent.operation.invocation_id),
         {:ok, target} <-
           Map.fetch(intents, "tool:" <> receipt.target_intent.operation.invocation_id),
         :ok <-
           ensure(
             outer === receipt.outer_intent and target === receipt.target_intent,
             :invalid_native_receipt
           ),
         :ok <-
           ensure(
             intent?(outer, locator, receipt.turn_id, origin["caller"]) and
               intent?(target, locator, receipt.turn_id, origin["caller"]),
             :invalid_native_receipt
           ),
         op = outer.operation,
         target_op = target.operation,
         :ok <-
           ensure(
             op.tool_name === "exec" and op.arguments === @source and
               op.enclosing_invocation_id === op.invocation_id and op.tool_revision === 1,
             :invalid_native_receipt
           ),
         :ok <-
           ensure(
             target_op.tool_name === request.target.tool_name and
               target_op.tool_revision === request.target.tool_revision and
               Filesystem.canonical_arguments?(
                 target_op.tool_name,
                 request.target.arguments,
                 target_op.arguments
               ) and
               target_op.enclosing_invocation_id === op.invocation_id,
             :invalid_native_receipt
           ),
         :ok <-
           ensure(
             Enum.all?(~w(turn_id step_id attempt_id)a, &(target_op[&1] === op[&1])),
             :invalid_native_receipt
           ),
         :ok <-
           ensure(
             Enum.all?(
               Map.values(intents),
               &(&1.operation.tool_name in ["exec", "wait", request.target.tool_name])
             ),
             :invalid_native_receipt
           ),
         :ok <-
           ensure(
             Enum.count(
               Map.values(intents),
               &(&1.operation.tool_name === request.target.tool_name)
             ) === 1 and
               Enum.count(
                 Map.values(intents),
                 &(&1.operation.tool_name === "exec" and &1.operation.arguments === @source and
                     &1.operation.enclosing_invocation_id === &1.operation.invocation_id)
               ) === 1,
             :invalid_native_receipt
           ),
         {:ok, target_result} <- Map.fetch(run.tool_results, target_op.invocation_id),
         :ok <-
           ensure(
             is_map(target_result) and target_result[:is_error] === false and
               not Map.has_key?(run.tool_presentations, target_op.invocation_id),
             :invalid_native_receipt
           ),
         %{"revision" => 1, "descriptor_digest" => digest} <- run.context.headless_catalog,
         :ok <- ensure(nonempty?(digest), :invalid_native_receipt),
         :ok <-
           ensure(
             receipt === %{
               version: 1,
               run_id: locator.run_id,
               incarnation: locator.incarnation,
               turn_id: op.turn_id,
               catalog_revision: 1,
               catalog_digest: digest,
               outer_intent: outer,
               target_intent: target,
               target_result: target_result,
               target_presentation: nil,
               final_revision: aggregate.revision
             },
             :invalid_native_receipt
           ) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_native_receipt}
    end
  end

  defp intent?(
         %{type: :tool, status: :consumed, operation: op, reservation: reservation},
         locator,
         turn_id,
         caller
       ) do
    op.run_id === locator.run_id and op.incarnation === locator.incarnation and
      op.turn_id === turn_id and op.caller === caller and op.catalog_revision === 1 and
      Enum.all?(~w(invocation_id tool_call_id turn_id step_id attempt_id)a, &nonempty?(op[&1])) and
      reservation.reservation_id === "tool:" <> op.invocation_id
  end

  defp intent?(_, _, _, _), do: false

  defp retirement?(retirement, origin) do
    keys?(retirement, ~w(resource_handle release headless session registry)a) and
      retirement.release === :confirmed and retirement.headless === :normal and
      retirement.session === :normal and retirement.registry === :normal and
      keys?(retirement.resource_handle, ~w(resource_id owner_id incarnation kind)a) and
      nonempty?(retirement.resource_handle.resource_id) and
      retirement.resource_handle.owner_id === origin["resource_owner_id"] and
      retirement.resource_handle.incarnation === origin["resource_incarnation"] and
      retirement.resource_handle.kind === :workflow_effect
  end

  # Store already owns opaque term persistence. This only rejects live values;
  # it neither serializes nor projects any part of the retained success.
  defp native_value?(value) when is_map(value) and not is_struct(value),
    do: Enum.all?(value, fn {key, item} -> native_value?(key) and native_value?(item) end)

  defp native_value?([]), do: true
  defp native_value?([head | tail]), do: native_value?(head) and native_value?(tail)
  defp native_value?(value) when is_atom(value) or is_binary(value) or is_number(value), do: true
  defp native_value?(_), do: false

  defp live_deadline(context) do
    with callback when is_function(callback, 0) <-
           context.operation.backend_context[:effect_deadline],
         {:ok, %{deadline_ms: deadline, remaining_ms: remaining, paused: false}} <- callback.(),
         true <-
           is_integer(deadline) and is_integer(remaining) and remaining > 0 and deadline > now() do
      {:ok, min(deadline, now() + remaining)}
    else
      _ -> {:error, :resource_conflict}
    end
  end

  defp fixed_deadline(deadline) do
    if is_integer(deadline) and deadline > now(), do: {:ok, deadline}, else: {:error, :timeout}
  end

  # Existing runtime reads have their own fixed request timeout. Check the live
  # deadline on both sides without claiming to cancel a late native operation.
  defp read_io(deadline, function) do
    with {:ok, current_deadline} <- deadline.() do
      case function.(current_deadline) do
        {:ok, _} = result ->
          with {:ok, _} <- deadline.(), do: result

        other ->
          other
      end
    end
  end

  defp step(stage, record, attempted_revision, function) do
    case function.() do
      :ok -> :ok
      {:ok, _} = result -> result
      {:error, %{stage: _, record: _}} = error -> error
      {:error, reason} -> problem(stage, reason, record, attempted_revision)
      :not_found -> problem(stage, :not_found, record, attempted_revision)
      _ -> problem(stage, :unknown_outcome, record, attempted_revision)
    end
  rescue
    _ -> problem(stage, :unknown_outcome, record, attempted_revision)
  catch
    _, _ -> problem(stage, :unknown_outcome, record, attempted_revision)
  end

  defp problem(stage, reason, record, attempted_revision),
    do:
      {:error,
       %{stage: stage, reason: reason, record: record, attempted_revision: attempted_revision}}

  defp ensure(true, _), do: :ok
  defp ensure(_, reason), do: {:error, reason}

  defp keys?(value, keys),
    do: is_map(value) and not is_struct(value) and Enum.sort(Map.keys(value)) === Enum.sort(keys)

  defp positive?(value), do: is_integer(value) and value > 0

  defp nonempty?(value),
    do: is_binary(value) and String.valid?(value) and String.trim(value) != ""

  defp uuid?(value), do: is_binary(value) and match?({:ok, ^value}, Ecto.UUID.cast(value))
  defp now, do: System.monotonic_time(:millisecond)
end
