defmodule Synapsis.Agent.Tools.Workflows.Segment do
  @moduledoc """
  Trusted durable driver for inline workflow segments.

  Runs inside an actual admitted native tool task. Continuations owns storage
  CAS; Machine owns semantics; Schema owns actual validation acknowledgements;
  the parent Session resource registry owns helper cleanup. There is no public
  descriptor, scheduler or automatic resume here. Opt-in v2 effects use the
  existing Journal with caller-supplied request and raw-response adapters.
  Internal v3 state driving uses explicit admitted source scope, observed Live
  publication and read-only fact verification before a fresh resume claim.
  """

  alias Backplane.AgentRuntime.Codex.{ResourceRegistry, Session}
  alias Synapsis.Agent.Tools.Workflows.Journal
  alias Synapsis.Filesystem.Local
  alias Synapsis.Workflow.{Continuations, Live, Schema, Sort, Template}
  alias Synapsis.Workflow.Schema.PortSession
  alias Synapsis.Workflow.Segment, as: Core

  @doc "Creates, drives and acknowledges one admitted inline segment."
  def run(pipeline, context) do
    with {:ok, agent_id} <- identity(context),
         {:ok, snapshot} <-
           step(:new, nil, nil, fn ->
             with {:ok, options} <- file_options(context, []), do: Core.new(pipeline, options)
           end),
         {:ok, record} <-
           step(:create, nil, 1, fn ->
             with {:ok, deadline} <- live_deadline(context) do
               Continuations.create(context.session_id, agent_id, snapshot, deadline: deadline)
             end
           end) do
      with_resource(record, context, fn broker ->
        finish_segment(record, record.snapshot, broker, context)
      end)
    end
  end

  @doc false
  def run_state(pipeline, context, %{state_scope: scope, provenance_owner: owner} = options)
      when map_size(options) == 2 do
    with {:ok, agent_id} <- identity(context),
         {:ok, snapshot} <-
           step(:new, nil, nil, fn ->
             with :ok <- admitted_state_scope(scope, context),
                  {:ok, options} <- file_options(context, version: 3, state_scope: scope) do
               Core.new(pipeline, options)
             end
           end),
         {:ok, record} <-
           step(:create, nil, 1, fn ->
             with {:ok, deadline} <- live_deadline(context) do
               Continuations.create(context.session_id, agent_id, snapshot, deadline: deadline)
             end
           end) do
      with_state_resource(record, context, owner, fn broker, binding ->
        finish_state(record, record.snapshot, broker, binding, context)
      end)
    end
  end

  @doc false
  def resume_state(
        workflow_id,
        expected_revision,
        response_json,
        context,
        %{provenance_owner: owner} = options
      )
      when map_size(options) == 1 do
    with {:ok, agent_id} <- identity(context),
         {:ok, %{record: record}} <-
           step(:reopen, nil, nil, fn ->
             with {:ok, deadline} <- live_deadline(context) do
               Journal.reopen_segment(
                 context.session_id,
                 agent_id,
                 workflow_id,
                 expected_revision,
                 deadline: deadline
               )
             end
           end),
         {:ok, _} <-
           step(:state_scope, record, nil, fn ->
             with :ok <- ensure(record.snapshot["version"] === 3, :invalid_segment_snapshot),
                  :ok <- saved_file_scope(record.snapshot, context),
                  :ok <- admitted_state_scope(record.snapshot["source"]["state_scope"], context),
                  do: {:ok, :admitted}
           end) do
      # The graph starts from the saved heap, before response import, with no marks.
      with_state_resource(record, context, owner, fn broker, binding ->
        with {:ok, resumed} <-
               step(:resume, record, nil, fn ->
                 publish_state_observed(
                   binding,
                   record.snapshot,
                   Core.resume_observed(record.snapshot, response_json),
                   nil,
                   context
                 )
               end),
             {:ok, validated} <-
               drive_state(
                 elem(resumed.transition, 1),
                 broker,
                 resumed.binding,
                 context,
                 :claim,
                 record
               ),
             {:ok, claimed} <- commit(validated.record, validated.snapshot, context, :claim) do
          finish_state(claimed, claimed.snapshot, broker, validated.binding, context)
        end
      end)
    end
  end

  @doc false
  def decode_state_token("workflow-segment.v3." <> encoded) do
    with {:ok, raw} <- Base.url_decode64(encoded, padding: false),
         {:ok, %{"workflowId" => id, "revision" => revision} = payload} <- Jason.decode(raw),
         true <- map_size(payload) == 2 and uuid?(id) and is_integer(revision) and revision > 0 do
      {:ok, %{workflow_id: id, revision: revision}}
    else
      _ -> {:error, :invalid_resume_token}
    end
  end

  def decode_state_token(_), do: {:error, :invalid_resume_token}

  defp admitted_state_scope(
         %{
           "kind" => "trusted_internal",
           "project_root" => root,
           "state_dir" => dir,
           "process_cwd" => cwd
         } = scope,
         context
       )
       when map_size(scope) == 4 do
    with {:ok, _} <- live_deadline(context),
         true <-
           absolute_path?(root) and Path.expand(root) === root and
             absolute_path?(cwd) and Path.expand(cwd) === cwd and nonempty?(dir),
         {:ok, admitted, _} <- Local.resolve(context[:project_root], "."),
         {:ok, captured, _} <- Local.resolve(root, "."),
         :ok <- ensure(admitted === captured and root === captured, :scope_mismatch) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_state_scope}
    end
  end

  defp admitted_state_scope(_, _), do: {:error, :invalid_state_scope}

  defp finish_state(record, snapshot, broker, binding, context) do
    with {:ok, boundary} <- drive_state(snapshot, broker, binding, context, :boundary, record),
         {:ok, committed} <- commit(boundary.record, boundary.snapshot, context, :boundary_commit) do
      {:ok, %{record: committed, binding: boundary.binding}}
    end
  end

  defp drive_state(snapshot, broker, binding, context, mode, record) do
    with {:ok, _} <- step(:deadline, record, nil, fn -> live_deadline(context) end) do
      if mode == :claim and Core.resume_ready?(snapshot) do
        {:ok, %{record: record, snapshot: snapshot, binding: binding}}
      else
        with {:ok, observed} <-
               step(:advance, record, nil, fn ->
                 publish_state_observed(
                   binding,
                   snapshot,
                   Core.advance_observed(snapshot),
                   nil,
                   context
                 )
               end) do
          case observed.transition do
            {:continue, next} ->
              drive_state(next, broker, observed.binding, context, mode, record)

            {:request, %{"kind" => kind}, pending}
            when kind in ["state_get", "state_set", "state_diff"] and mode == :boundary ->
              with {:ok, executed} <-
                     Journal.run_state_segment(record, pending, observed.binding, context, %{
                       broker: broker
                     }) do
                drive_state(
                  executed.record.snapshot,
                  broker,
                  executed.binding,
                  context,
                  mode,
                  executed.record
                )
              end

            {:request, %{"kind" => kind}, pending}
            when kind in [
                   "compile_schema",
                   "validate_response",
                   "sort_items",
                   "render_template",
                   "read_template_file"
                 ] ->
              with {:ok, %{ack: ack}} <-
                     step(:helper_ack, record, nil, fn ->
                       state_helper_ack(kind, pending, broker, context)
                     end),
                   {:ok, acknowledged} <-
                     step(:helper_transition, record, nil, fn ->
                       publish_state_observed(
                         observed.binding,
                         pending,
                         Core.advance_observed(pending, ack),
                         nil,
                         context
                       )
                     end) do
                case acknowledged.transition do
                  {:continue, next} ->
                    drive_state(next, broker, acknowledged.binding, context, mode, record)

                  {:error, reason, _} ->
                    problem(:helper_transition, reason, record, nil)

                  _ ->
                    problem(:helper_transition, :invalid_helper_transition, record, nil)
                end
              end

            {kind, _value, boundary}
            when kind in [:checkpoint, :complete] and mode == :boundary ->
              {:ok, %{record: record, snapshot: boundary, binding: observed.binding}}

            {:error, reason, _} ->
              problem(:advance, reason, record, nil)

            _ ->
              problem(:advance, :unexpected_segment_transition, record, nil)
          end
        end
      end
    end
  end

  defp state_helper_ack("read_template_file", pending, broker, context),
    do:
      Template.ack_file(broker, pending["machine"], pending["source"]["file_scope"], fn ->
        live_deadline(context)
      end)

  defp state_helper_ack(kind, pending, broker, context) do
    with {:ok, timeout} <- state_timeout(context) do
      case kind do
        "sort_items" -> Sort.ack_pending(broker, pending["machine"], timeout)
        "render_template" -> Template.ack_pending(broker, pending["machine"], timeout)
        _ -> Schema.ack_pending(broker, pending["machine"], timeout)
      end
    end
  end

  defp publish_state_observed(
         binding,
         before,
         {transition, observations},
         source_context,
         context
       ) do
    case transition do
      {:error, reason} ->
        {:error, reason}

      _ ->
        snapshot = elem(transition, tuple_size(transition) - 1)
        machine_transition = put_elem(transition, tuple_size(transition) - 1, snapshot["machine"])

        with {:ok, timeout} <- state_timeout(context),
             {:ok, ^machine_transition, next_binding} <-
               Live.publish_observed(
                 binding,
                 before["machine"],
                 {machine_transition, observations},
                 source_context,
                 timeout
               ) do
          {:ok, %{transition: transition, binding: next_binding}}
        end
    end
  end

  defp state_timeout(context) do
    with {:ok, deadline} <- live_deadline(context),
         timeout = min(120_000, deadline - now()),
         :ok <- ensure(timeout > 0, :timeout),
         do: {:ok, timeout}
  end

  defp with_state_resource(record, context, owner, function) do
    with {:ok, resource} <- acquire(record, context) do
      opened =
        step(:live_open, record, nil, fn ->
          with {:ok, timeout} <- state_timeout(context),
               do: Live.open(owner, record.snapshot["machine"], timeout)
        end)

      case opened do
        {:ok, original} ->
          result = step(:segment, record, nil, fn -> function.(resource.broker, original) end)

          latest =
            case result do
              {:ok, %{record: acknowledged}} -> acknowledged
              _ -> acknowledged_record(result, record)
            end

          # Registry-confirmed Local cleanup implies callback/guardian quiescence.
          # Otherwise leave the monitored lease intact and report uncertainty.
          live_retirement =
            case result do
              {:error, %{quiescent: false}} ->
                problem(:live_retirement, :state_cleanup_unconfirmed, latest, nil)

              _ ->
                step(:live_retirement, latest, nil, fn ->
                  binding =
                    case result do
                      {:ok, %{binding: current}} -> current
                      _ -> original
                    end

                  case Live.retire(binding, 5_000) do
                    :ok -> {:ok, :confirmed}
                    error -> error
                  end
                end)
            end

          helper_retirement = retire(resource, latest, context)

          with {:ok, :confirmed} <- live_retirement,
               {:ok, evidence} <- helper_retirement,
               {:ok, %{record: completed}} <- result,
               {:ok, envelope} <-
                 step(:envelope, completed, nil, fn ->
                   Core.envelope(completed.snapshot, token(completed))
                 end) do
            {:ok, %{record: completed, envelope: envelope, retirement: evidence}}
          end

        error ->
          case retire(resource, record, context) do
            {:ok, _} -> error
            cleanup_error -> cleanup_error
          end
      end
    end
  end

  @doc "Validates and claims an exact checkpoint, then drives its fresh semantic segment."
  def resume(workflow_id, expected_revision, response_json, context) do
    with {:ok, agent_id} <- identity(context),
         {:ok, record} <-
           step(:load, nil, nil, fn ->
             with {:ok, deadline} <- live_deadline(context),
                  {:ok, record} <-
                    Continuations.load(context.session_id, workflow_id, deadline: deadline) do
               {:ok, record}
             end
           end),
         {:ok, snapshot} <-
           step(:resume, record, nil, fn ->
             with {:ok, _} <- live_deadline(context),
                  :ok <- ensure(record.agent_id === agent_id, :scope_mismatch),
                  :ok <- ensure(record.revision === expected_revision, :resource_conflict),
                  :ok <-
                    ensure(
                      record.snapshot["revision"] === record.revision,
                      :invalid_segment_revision
                    ),
                  :ok <- saved_file_scope(record.snapshot, context) do
               Core.resume(record.snapshot, response_json)
             end
           end) do
      with_resource(record, context, fn broker ->
        with {:ok, validated} <- drive(snapshot, broker, context, :claim, record),
             {:ok, claimed} <- commit(record, validated, context, :claim) do
          finish_segment(claimed, claimed.snapshot, broker, context)
        end
      end)
    end
  end

  @doc false
  def run_effects(pipeline, context, adapters) do
    with {:ok, agent_id} <- identity(context),
         {:ok, adapters} <- validate_adapters(adapters),
         {:ok, snapshot} <-
           step(:new, nil, nil, fn ->
             with {:ok, options} <- file_options(context, version: 2),
                  do: Core.new(pipeline, options)
           end),
         {:ok, record} <-
           step(:create, nil, 1, fn ->
             with {:ok, deadline} <- live_deadline(context) do
               Continuations.create(context.session_id, agent_id, snapshot, deadline: deadline)
             end
           end) do
      with_resource(record, context, fn broker ->
        finish_effects(record, record.snapshot, broker, context, adapters)
      end)
    end
  end

  @doc false
  def resume_effects(workflow_id, expected_revision, response_json, context, adapters) do
    with {:ok, agent_id} <- identity(context),
         {:ok, adapters} <- validate_adapters(adapters),
         {:ok, %{record: record}} <-
           step(:reopen, nil, nil, fn ->
             with {:ok, deadline} <- live_deadline(context) do
               Journal.reopen_segment(
                 context.session_id,
                 agent_id,
                 workflow_id,
                 expected_revision,
                 deadline: deadline
               )
             end
           end),
         {:ok, snapshot} <-
           step(:resume, record, nil, fn ->
             with {:ok, _} <- live_deadline(context),
                  :ok <- saved_file_scope(record.snapshot, context) do
               Core.resume(record.snapshot, response_json)
             end
           end) do
      with_resource(record, context, fn broker ->
        with {:ok, validated} <- drive(snapshot, broker, context, :claim, record, adapters),
             {:ok, claimed} <- commit(validated.record, validated.snapshot, context, :claim) do
          finish_effects(claimed, claimed.snapshot, broker, context, adapters)
        end
      end)
    end
  end

  defp finish_segment(record, snapshot, broker, context) do
    with {:ok, boundary} <- drive(snapshot, broker, context, :boundary, record) do
      commit(record, boundary, context, :boundary_commit)
    end
  end

  defp finish_effects(record, snapshot, broker, context, adapters) do
    with {:ok, boundary} <- drive(snapshot, broker, context, :boundary, record, adapters) do
      commit(boundary.record, boundary.snapshot, context, :boundary_commit)
    end
  end

  defp drive(snapshot, broker, context, mode, record) do
    with {:ok, %{snapshot: boundary}} <- drive(snapshot, broker, context, mode, record, nil) do
      {:ok, boundary}
    end
  end

  defp drive(snapshot, broker, context, mode, record, adapters) do
    with {:ok, _} <- step(:deadline, record, nil, fn -> live_deadline(context) end),
         {:ok, ready?} <-
           step(:resume_ready, record, nil, fn ->
             {:ok, mode == :claim and Core.resume_ready?(snapshot)}
           end) do
      if ready? do
        {:ok, %{record: record, snapshot: snapshot}}
      else
        with {:ok, transition} <-
               step(:advance, record, nil, fn -> {:ok, Core.advance(snapshot)} end) do
          case transition do
            {:continue, next} ->
              drive(next, broker, context, mode, record, adapters)

            {:request, %{"kind" => "invoke"} = request, %{"version" => 2} = pending}
            when mode == :boundary and is_map(adapters) ->
              invoke(record, request, pending, broker, context, adapters)

            {:request, %{"kind" => kind}, pending}
            when kind in ["read_template_file", "render_template"] ->
              with {:ok, next} <-
                     step(:template, record, nil, fn ->
                       template(kind, pending, broker, context)
                     end) do
                drive(next, broker, context, mode, record, adapters)
              end

            {:request, %{"kind" => "sort_items"}, pending} ->
              with {:ok, next} <-
                     step(:sort, record, nil, fn ->
                       with {:ok, deadline} <- live_deadline(context) do
                         timeout = min(120_000, deadline - now())

                         if timeout > 0 do
                           case Sort.advance_pending(broker, pending["machine"], timeout) do
                             {:continue, machine} -> {:ok, Map.put(pending, "machine", machine)}
                             {:error, reason, _machine} -> {:error, reason}
                             _ -> {:error, :invalid_sort_transition}
                           end
                         else
                           {:error, :timeout}
                         end
                       end
                     end) do
                drive(next, broker, context, mode, record, adapters)
              end

            {:request, _request, pending} ->
              with {:ok, next} <-
                     step(:schema, record, nil, fn ->
                       with {:ok, deadline} <- live_deadline(context) do
                         timeout = min(120_000, deadline - now())

                         if timeout > 0 do
                           case Schema.advance_pending(broker, pending["machine"], timeout) do
                             {:continue, machine} -> {:ok, Map.put(pending, "machine", machine)}
                             {:error, reason, _machine} -> {:error, reason}
                             _ -> {:error, :invalid_schema_transition}
                           end
                         else
                           {:error, :timeout}
                         end
                       end
                     end) do
                drive(next, broker, context, mode, record, adapters)
              end

            {kind, _value, boundary}
            when kind in [:checkpoint, :complete] and mode == :boundary ->
              {:ok, %{record: record, snapshot: boundary}}

            {:error, reason, _snapshot} ->
              problem(:advance, reason, record, nil)

            _ ->
              problem(:advance, :unexpected_segment_transition, record, nil)
          end
        end
      end
    end
  end

  defp template(kind, pending, broker, context) do
    transition =
      case kind do
        "read_template_file" ->
          Template.advance_file(
            broker,
            pending["machine"],
            pending["source"]["file_scope"],
            fn -> live_deadline(context) end
          )

        "render_template" ->
          with {:ok, deadline} <- live_deadline(context),
               timeout = min(120_000, deadline - now()),
               true <- timeout > 0 do
            Template.advance_pending(broker, pending["machine"], timeout)
          else
            {:error, reason} -> {:error, reason, pending["machine"]}
            false -> {:error, :timeout, pending["machine"]}
          end
      end

    case transition do
      {:continue, machine} -> {:ok, Map.put(pending, "machine", machine)}
      {:error, reason, _machine} -> {:error, reason}
      _ -> {:error, :invalid_template_transition}
    end
  end

  defp file_options(context, options) do
    case Map.fetch(context, :file_scope) do
      :error ->
        {:ok, options}

      {:ok, %{"project_root" => root, "cwd" => cwd} = scope}
      when map_size(scope) == 2 and is_binary(root) and is_binary(cwd) ->
        with {:ok, _} <- live_deadline(context),
             {:ok, trusted_root, _} <- Local.resolve(context[:project_root], "."),
             {:ok, scope_root, _} <- Local.resolve(root, "."),
             :ok <- ensure(trusted_root === scope_root, :scope_mismatch),
             :ok <- ensure(Path.type(cwd) == :relative, :invalid_template_file_scope),
             {:ok, _absolute, relative} <- Local.resolve(trusted_root, cwd) do
          {:ok,
           Keyword.put(options, :file_scope, %{"project_root" => trusted_root, "cwd" => relative})}
        end

      _ ->
        {:error, :invalid_template_file_scope}
    end
  end

  defp saved_file_scope(snapshot, context) do
    case Map.fetch(snapshot["source"], "file_scope") do
      :error ->
        :ok

      {:ok, %{"project_root" => root}} ->
        with {:ok, current, _} <- Local.resolve(context[:project_root], "."),
             do: ensure(current === root, :scope_mismatch)

      _ ->
        {:error, :invalid_template_file_scope}
    end
  end

  defp invoke(record, request, pending, broker, context, adapters) do
    with {:ok, native_request} <-
           step(:request, record, nil, fn ->
             with {:ok, _} <- live_deadline(context) do
               adapters.request.(request, record)
             end
           end),
         {:ok, %{record: settled, effect: effect}} <-
           step(:effect, record, nil, fn ->
             Journal.run_segment(record, pending, native_request, context)
           end),
         {:ok, response_json} <-
           step(:response_json, settled, nil, fn ->
             with {:ok, _} <- live_deadline(context) do
               adapters.response_json.(effect)
             end
           end),
         {:ok, %{record: consumed}} <-
           step(:consume, settled, nil, fn ->
             Journal.consume_segment(settled, response_json, context)
           end) do
      # Each primitive carries its latest actual CAS ACK. Recurse only after
      # those wrappers return, so pure progress and effects retain no loop frame.
      drive(consumed.snapshot, broker, context, :boundary, consumed, adapters)
    end
  end

  defp validate_adapters(adapters) do
    step(:adapters, nil, nil, fn ->
      case adapters do
        %{request: request, response_json: response_json}
        when map_size(adapters) == 2 and is_function(request, 2) and
               is_function(response_json, 1) ->
          {:ok, adapters}

        _ ->
          {:error, :invalid_effect_adapters}
      end
    end)
  end

  defp commit(record, snapshot, context, stage) do
    revision = record.revision + 1

    step(stage, record, revision, fn ->
      with {:ok, deadline} <- live_deadline(context) do
        # A known successful CAS ACK remains acknowledged even if it is late.
        Continuations.commit(
          record.session_id,
          record.id,
          record.revision,
          Map.put(snapshot, "revision", revision),
          deadline: deadline
        )
      end
    end)
  end

  defp with_resource(record, context, function) do
    with {:ok, resource} <- acquire(record, context) do
      result = step(:segment, record, nil, fn -> function.(resource.broker) end)
      latest = acknowledged_record(result, record)
      retirement = retire(resource, latest, context)

      with {:ok, record} <- result,
           {:ok, evidence} <- retirement,
           {:ok, envelope} <-
             step(:envelope, record, nil, fn -> Core.envelope(record.snapshot, token(record)) end) do
        {:ok, %{record: record, envelope: envelope, retirement: evidence}}
      else
        # Cleanup uncertainty takes precedence over semantic errors: neither
        # result may be published as success while helper retirement is unknown.
        error ->
          case retirement do
            {:error, _} = cleanup_error -> cleanup_error
            _ -> error
          end
      end
    end
  end

  defp acquire(record, context) do
    binding = context.session_binding

    with {:ok, supervisor} <-
           step(:resource_supervisor, record, nil, fn ->
             with {:ok, _} <- live_deadline(context),
                  do: ResourceRegistry.worker_supervisor(binding.resource_registry)
           end),
         {:ok, broker} <-
           step(:helper_start, record, nil, fn ->
             with {:ok, _} <- live_deadline(context) do
               DynamicSupervisor.start_child(
                 supervisor,
                 {PortSession,
                  owner_pid: self(),
                  node_executable: context.schema_runtime.node_executable,
                  helper_path: context.schema_runtime.helper_path}
               )
             end
           end) do
      # The broker is dormant until fulfill; register its owner before first use.
      registration =
        step(:resource_register, record, nil, fn ->
          with {:ok, _} <- live_deadline(context) do
            ResourceRegistry.register(
              binding.resource_registry,
              binding.owner_id,
              :workflow_schema,
              broker,
              incarnation: binding.incarnation,
              owner_pid: self(),
              cleanup: fn -> cleanup(supervisor, broker) end
            )
          end
        end)

      case registration do
        {:ok, handle} ->
          {:ok, %{supervisor: supervisor, broker: broker, handle: handle}}

        error ->
          case cleanup(supervisor, broker) do
            :ok -> error
            _ -> problem(:retirement, :helper_cleanup_unconfirmed, record, nil)
          end
      end
    end
  end

  defp retire(resource, record, context) do
    binding = context.session_binding

    closed =
      step(:helper_close, record, nil, fn ->
        case PortSession.close(resource.broker) do
          {:ok, %{cleanup_confirmed: true} = status} -> {:ok, status}
          _ -> {:error, :helper_cleanup_unconfirmed}
        end
      end)

    # Cleanup remains required after the operation's semantic deadline. The
    # registry has its own bounded cleanup task; release waits for its actual ACK.
    released =
      step(:resource_release, record, nil, fn ->
        with {:ok, :ok} <-
               ResourceRegistry.release(
                 binding.resource_registry,
                 resource.handle,
                 binding.owner_id
               ),
             {:ok, %{status: :confirmed}} <-
               ResourceRegistry.cleanup_status(
                 binding.resource_registry,
                 resource.handle,
                 binding.owner_id
               ),
             :ok <- ensure(not Process.alive?(resource.broker), :helper_cleanup_unconfirmed) do
          {:ok, :confirmed}
        else
          {:error, _} = error -> error
          _ -> {:error, :helper_cleanup_unconfirmed}
        end
      end)

    with {:ok, status} <- closed,
         {:ok, :confirmed} <- released do
      {:ok,
       %{
         resource_handle: resource.handle,
         release: :confirmed,
         helper: status,
         broker: :terminated
       }}
    end
  end

  defp cleanup(supervisor, broker) do
    # retire/3 may already have received the helper's actual normal-close ACK.
    # The registry still owns broker termination, without issuing close twice.
    closed =
      case PortSession.status(broker) do
        %{cleanup_confirmed: true, exit_status: 0} = status -> {:ok, status}
        %{cleanup_confirmed: true, reason: :never_started} = status -> {:ok, status}
        _ -> PortSession.close(broker)
      end

    with {:ok, %{cleanup_confirmed: true}} <- closed,
         :ok <- DynamicSupervisor.terminate_child(supervisor, broker) do
      :ok
    else
      _ -> {:uncertain, :workflow_schema_cleanup_unconfirmed}
    end
  catch
    :exit, _ -> {:uncertain, :workflow_schema_cleanup_unconfirmed}
  end

  defp identity(context) do
    step(:identity, nil, nil, fn ->
      with %{
             profiles_context: %{session: %{id: session_id}, agent: %{id: agent_id, name: name}},
             session_id: session_id,
             caller: caller,
             operation: operation,
             session_binding: binding,
             schema_runtime: %{node_executable: node, helper_path: helper}
           } <- context,
           :ok <-
             ensure(uuid?(session_id) and uuid?(agent_id) and nonempty?(name), :invalid_identity),
           :ok <-
             ensure(is_map(operation) and is_map(binding) and nonempty?(caller), :invalid_context),
           :ok <- ensure(operation[:caller] === caller, :scope_mismatch),
           :ok <-
             ensure(absolute_path?(node) and absolute_path?(helper), :invalid_schema_runtime),
           {:ok, _} <- live_deadline(context),
           saved = Synapsis.AgentConfigs.get(agent_id),
           :ok <-
             ensure(
               match?(%Synapsis.AgentConfig{id: ^agent_id, name: ^name, enabled: true}, saved),
               :invalid_identity
             ),
           {:ok, _} <- live_deadline(context),
           {:ok, _} <- Session.validate(binding, operation),
           {:ok, _} <- live_deadline(context) do
        {:ok, agent_id}
      else
        {:error, _} = error -> error
        _ -> {:error, :invalid_context}
      end
    end)
  end

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

  defp token(%{snapshot: %{"version" => version}} = record) when version in [2, 3] do
    "workflow-segment.v#{version}." <>
      Base.url_encode64(
        Jason.encode!(%{"workflowId" => record.id, "revision" => record.revision}),
        padding: false
      )
  end

  defp token(record) do
    "workflow-segment.v1." <>
      Base.url_encode64(
        Jason.encode!(%{"workflowId" => record.id, "revision" => record.revision}),
        padding: false
      )
  end

  defp acknowledged_record({:ok, record}, _previous), do: record
  defp acknowledged_record({:error, %{record: record}}, _previous) when is_map(record), do: record
  defp acknowledged_record(_result, previous), do: previous

  defp step(stage, record, revision, function) do
    case function.() do
      {:ok, _} = result -> result
      {:error, %{stage: _, record: _}} = error -> error
      {:error, reason} -> problem(stage, reason, record, revision)
      :not_found -> problem(stage, :not_found, record, revision)
      _ -> problem(stage, :unknown_outcome, record, revision)
    end
  rescue
    _ -> problem(stage, :unknown_outcome, record, revision)
  catch
    _, _ -> problem(stage, :unknown_outcome, record, revision)
  end

  defp problem(stage, reason, record, revision),
    do: {:error, %{stage: stage, reason: reason, record: record, attempted_revision: revision}}

  defp ensure(true, _reason), do: :ok
  defp ensure(_value, reason), do: {:error, reason}
  defp uuid?(value), do: is_binary(value) and match?({:ok, ^value}, Ecto.UUID.cast(value))

  defp nonempty?(value),
    do: is_binary(value) and String.valid?(value) and String.trim(value) != ""

  defp absolute_path?(value), do: nonempty?(value) and Path.type(value) == :absolute
  defp now, do: System.monotonic_time(:millisecond)
end
