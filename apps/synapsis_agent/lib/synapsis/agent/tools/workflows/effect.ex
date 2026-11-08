defmodule Synapsis.Agent.Tools.Workflows.Effect do
  @moduledoc """
  One owned native Filesystem occurrence inside an admitted supervised effect task.

  Trusted host context carries the original Profiles snapshot and authority.
  The locator records intent before startup; it is not a workflow checkpoint or
  deduplication claim. Each call dispatches once into a fresh provider-free native
  Session and Headless run. Success requires durable settlement and acknowledged
  parent resource release with observed normal retirement of the owned tree.

  Native Goal attribution is delegated to the child and acknowledged before
  retirement. Selected deferred-tool contexts are refused before retention or
  startup. No public route is exposed.
  """

  alias Backplane.AgentRuntime.{Error, Goal, ToolCatalog}
  alias Backplane.AgentRuntime.Policy, as: NativePolicy
  alias Backplane.AgentRuntime.Codex.{Headless, ResourceRegistry, Session}
  alias Synapsis.Agent.Runtime.{RunInventory, Store}
  alias Synapsis.Agent.Tools.{CodeMode, Filesystem, Freshness, Policy, Profiles}

  @source "// @exec: {\"yield_time_ms\": 1000}\nreturn await tools[input.tool_name](input.arguments);\n"
  @scope [:run_id, :incarnation, :catalog_revision]
  @limits ~w(timeout_ms effect_timeout_ms commit_timeout_ms cleanup_timeout_ms output_limit work)a

  def run(request, context) when is_map(request) and is_map(context) do
    safe(fn ->
      with :ok <- validate(request, context),
           {:ok, _} <- Session.validate(context.session_binding, context.operation),
           :ok <- parent(request, context),
           {:ok, deadline} <- deadline(request, context.operation),
           identity = %{
             caller: context.caller,
             session_id: context.session_id,
             run_id: Ecto.UUID.generate(),
             incarnation: context.store.incarnation,
             catalog_revision: 1
           },
           locator =
             RunInventory.workflow_effect(
               context.session_id,
               context.store,
               identity,
               context.operation,
               request
             ),
           :ok <- RunInventory.retain(locator) do
        safe(fn -> start(request, context, identity, locator, deadline) end)
        |> evidence(locator, request.correlation)
      end
    end)
    |> normalize()
  end

  def run(_, _),
    do: failure(:validation, "workflow effect requires request and trusted host context")

  defp validate(request, context) do
    with %{correlation: correlation, target: target, limits: limits} <- request,
         true <- keys?(request, [:correlation, :target, :limits]),
         %{workflow_id: workflow, request_id: request_id, segment: segment} <- correlation,
         true <- keys?(correlation, [:workflow_id, :request_id, :segment]),
         {:ok, _} <- Ecto.UUID.cast(workflow),
         true <- nonempty?(request_id) and is_integer(segment) and segment >= 0,
         %{tool_name: name, tool_revision: revision, arguments: arguments} <- target,
         true <- keys?(target, [:tool_name, :tool_revision, :arguments]),
         true <- name in Filesystem.names() and is_integer(revision) and revision > 0,
         true <- is_map(arguments) and not is_struct(arguments) and json?(arguments),
         true <- keys?(limits, @limits),
         true <- Enum.all?(@limits, &(is_integer(limits[&1]) and limits[&1] > 0)),
         true <-
           Enum.all?(
             ~w(timeout_ms effect_timeout_ms commit_timeout_ms)a,
             &(limits[&1] <= 3_600_000)
           ),
         true <- limits.cleanup_timeout_ms <= 60_000,
         %{
           operation: operation,
           session_binding: binding,
           profiles_context: profiles,
           profiles_snapshot: snapshot,
           ceiling: ceiling,
           store: %{namespace: namespace, incarnation: incarnation},
           session_id: session_id,
           caller: caller
         } <- context,
         true <- Enum.all?([operation, binding, profiles, snapshot, ceiling], &is_map/1),
         true <- nonempty?(namespace) and is_integer(incarnation) and incarnation > 0,
         true <- nonempty?(session_id) and nonempty?(caller),
         true <- is_map(operation[:backend_context]),
         true <- goal_pair?(operation.backend_context),
         true <- is_function(context[:workflow_effect_registration], 4),
         %{session: %{id: ^session_id}, agent: %{tools: tools} = agent} <- profiles,
         true <- is_list(tools) and agent[:tool_contract_version] === 1,
         true <- Enum.all?(selection(request), &(&1 in tools)),
         deferred = Map.get(agent, :deferred_tool_names, []),
         true <- is_list(deferred) and Enum.all?(selection(request), &(&1 not in deferred)) do
      :ok
    else
      _ ->
        failure(
          :validation,
          "workflow effect requires exact Filesystem input, finite limits and supported original host context"
        )
    end
  end

  defp goal_pair?(backend) do
    case {backend[:goal], backend[:goal_binding]} do
      {nil, nil} -> true
      {goal, binding} -> is_pid(goal) and is_map(binding) and not is_struct(binding)
    end
  end

  defp parent(request, context) do
    operation = context.operation
    snapshot = context.profiles_snapshot
    ceiling = context.ceiling
    names = selection(request)

    with %{revision: revision, registry: %{tools: descriptors}, authority: authority} = pinned <-
           operation.backend_context[:catalog_snapshot],
         true <- is_integer(revision) and revision > 0 and is_map(descriptors),
         true <- operation[:effective_authority] === authority,
         true <-
           authority[:caller] === context.caller and authority[:run_id] === operation.run_id,
         true <- operation[:caller] === context.caller,
         true <-
           snapshot.scope[:session_id] === context.session_id and
             snapshot.scope[:caller] === context.caller,
         true <- Enum.all?(@scope, &(snapshot.scope[&1] === operation[&1])),
         true <- operation.catalog_revision === revision,
         true <- subset?(authority, ceiling),
         true <-
           Enum.all?(names, fn name ->
             descriptor = descriptors[name]

             is_map(descriptor) and name in authority.grants and name in ceiling.grants and
               descriptor === snapshot.issued_descriptors[name] and
               descriptor.tool_revision === revision(authority, name) and
               descriptor.tool_revision === revision(ceiling, name) and
               not Map.has_key?(Map.get(authority, :tool_bindings, %{}), name) and
               not Map.has_key?(Map.get(ceiling, :tool_bindings, %{}), name)
           end),
         true <-
           Enum.all?(["exec", "wait"], fn name ->
             descriptor = descriptors[name]

             descriptor.backend === Backplane.AgentRuntime.Codex.Backend and
               descriptor.backend_context.family === :code_mode and
               descriptor.backend_context.session_binding === context.session_binding
           end),
         target = descriptors[request.target.tool_name],
         true <-
           target.backend === Filesystem and target.tool_revision === request.target.tool_revision,
         true <- Enum.all?(@scope, &(target.backend_context[&1] === operation[&1])),
         true <- target.backend_context.root === context.profiles_context.project_path,
         true <-
           target.backend_context.workspace === %{
             role: :session,
             agent_id: context.profiles_context.agent.name,
             session_id: context.session_id
           },
         descriptor when is_map(descriptor) <- descriptors[operation.tool_name],
         true <- descriptor.tool_revision === operation.tool_revision,
         {:ok, _} <- NativePolicy.authorize_tool(authority, descriptor, operation),
         {:ok, _} <-
           ToolCatalog.admit_batch([descriptor],
             authority: narrow(authority, [operation.tool_name], operation.run_id),
             run_id: operation.run_id,
             mode: :strict
           ),
         true <- pinned.authority === operation.effective_authority do
      :ok
    else
      {:error, %Error{}} = error ->
        error

      _ ->
        failure(
          :forbidden,
          "workflow effect original live catalog authority or selected descriptor provenance changed"
        )
    end
  end

  defp subset?(authority, ceiling) do
    is_map(authority) and is_map(ceiling) and is_list(authority[:grants]) and
      is_list(ceiling[:grants]) and
      Map.drop(authority, [:grants, :tool_revisions, :tool_bindings]) ===
        Map.drop(ceiling, [:grants, :tool_revisions, :tool_bindings]) and
      Enum.all?(authority.grants, fn name ->
        name in ceiling.grants and revision(authority, name) === revision(ceiling, name) and
          Map.get(Map.get(authority, :tool_bindings, %{}), name) ===
            Map.get(Map.get(ceiling, :tool_bindings, %{}), name)
      end)
  end

  defp narrow(authority, names, run_id) do
    authority
    |> Map.put(:run_id, run_id)
    |> Map.put(:grants, names)
    |> Map.update(:tool_revisions, %{}, &Map.take(&1, names))
    |> then(fn narrowed ->
      if Map.has_key?(narrowed, :tool_bindings),
        do: Map.update!(narrowed, :tool_bindings, &Map.take(&1, names)),
        else: narrowed
    end)
  end

  defp deadline(request, operation) do
    with callback when is_function(callback, 0) <- operation.backend_context[:effect_deadline],
         {:ok, %{deadline_ms: parent, remaining_ms: remaining, paused: false}} <- callback.(),
         true <- is_integer(parent) and is_integer(remaining) and remaining > 0 and parent > now() do
      {:ok, min(parent, now() + min(remaining, request.limits.timeout_ms))}
    else
      _ ->
        failure(:resource_conflict, "workflow effect requires an active finite native deadline")
    end
  end

  defp start(request, context, identity, locator, deadline) do
    case Session.start_link(owner_pid: self(), cleanup_timeout: request.limits.cleanup_timeout_ms) do
      {:ok, session} ->
        owned = %{
          session: session,
          headless: nil,
          registry: nil,
          goal: nil,
          goal_binding: nil,
          goal_ack: nil,
          ticket: nil,
          catalog: nil
        }

        authority =
          narrow(context.operation.effective_authority, selection(request), identity.run_id)

        case safe(fn -> Session.bind(session, authority, incarnation: identity.incarnation) end) do
          {:ok, binding} ->
            owned = %{owned | registry: binding.resource_registry}

            case registration(request, context, identity, binding, deadline) do
              {:ok, ticket} ->
                start_registered_child(
                  %{owned | ticket: ticket},
                  request,
                  context,
                  identity,
                  binding,
                  authority,
                  locator,
                  deadline
                )

              error ->
                startup_error(owned, request, error)
            end

          error ->
            startup_error(owned, request, error)
        end

      error ->
        error
    end
  end

  defp registration(request, context, identity, binding, deadline) do
    proof = %{
      identity:
        Map.take(
          context.operation,
          ~w(caller run_id incarnation catalog_revision invocation_id tool_name tool_revision turn_id step_id attempt_id tool_call_id)a
        ),
      catalog: context.operation.backend_context.catalog_snapshot,
      authority: context.operation.effective_authority,
      deadline_ms: deadline,
      call_timeout_ms: min(5_000, request.limits.cleanup_timeout_ms)
    }

    safe(fn ->
      context.workflow_effect_registration.(
        proof,
        identity,
        binding,
        Map.take(request.target, [:tool_name, :tool_revision])
      )
    end)
  end

  defp start_registered_child(
         owned,
         request,
         context,
         identity,
         binding,
         authority,
         locator,
         deadline
       ) do
    case safe(fn ->
           child(request, context, identity, binding, authority, deadline, owned.ticket)
         end) do
      {:ok, options} ->
        owned = %{owned | catalog: ToolCatalog.initial(options)}

        case safe(fn ->
               delegate(context.operation.backend_context, identity, options[:authority])
             end) do
          {:ok, goal_options} ->
            owned = %{
              owned
              | goal: goal_options[:goal],
                goal_binding: goal_options[:goal_binding],
                goal_ack: if(goal_options[:goal_binding], do: :atomics.new(1, []))
            }

            case safe(fn -> Headless.start_link(options ++ goal_options) end) do
              {:ok, child} ->
                registered(%{owned | headless: child}, request, context, locator, deadline)

              error ->
                startup_error(owned, request, error)
            end

          error ->
            startup_error(owned, request, error)
        end

      error ->
        startup_error(owned, request, error)
    end
  end

  defp delegate(%{goal: goal, goal_binding: parent}, identity, authority)
       when is_pid(goal) and is_map(parent) do
    with {:ok, binding} <-
           Goal.delegate(goal, parent, %{
             thread_id: identity.run_id,
             run_id: identity.run_id,
             incarnation: identity.incarnation,
             authority: authority
           }) do
      {:ok, [goal: goal, goal_binding: binding, thread_id: binding.thread_id]}
    end
  end

  defp delegate(_, _, _), do: {:ok, []}

  defp child(request, context, identity, binding, authority, deadline, ticket) do
    names = selection(request)
    agent = Map.put(context.profiles_context.agent, :tools, names)

    agent =
      if Map.has_key?(agent, :deferred_tool_names),
        do:
          Map.update!(agent, :deferred_tool_names, &Enum.filter(&1, fn name -> name in names end)),
        else: agent

    profiles =
      context.profiles_context
      |> Map.put(:agent, agent)
      |> Map.put(:tool_session_binding, binding)
      |> Map.put(:tool_filesystem, ticket.tool_filesystem)

    with {:ok, bundles} <- CodeMode.bundles(%{session_binding: binding}, authority, names),
         {:ok, %{bundle: bundle, snapshot: snapshot}} <-
           Profiles.build(profiles, identity, bundles, authority),
         true <- Enum.sort(Map.keys(bundle.registry.tools)) === Enum.sort(names),
         true <- snapshot.permission === context.profiles_snapshot.permission,
         :ok <- Freshness.check(context.profiles_snapshot.evidence, snapshot.evidence),
         true <-
           child_descriptors?(
             bundle.registry.tools,
             context.profiles_snapshot.issued_descriptors,
             names,
             binding,
             identity,
             ticket
           ),
         true <- bundle.authority === ticket.authority,
         {:ok, host_context} <- ticket.activate.(bundle, snapshot),
         timeout when timeout > 0 <- deadline - now() do
      {:ok,
       [
         run_id: identity.run_id,
         incarnation: identity.incarnation,
         session_binding: binding,
         registry: bundle.registry,
         tools: bundle.tools,
         authority: bundle.authority,
         store: Store,
         context: context.store,
         hooks: Policy,
         host_context: host_context,
         subscriber: self(),
         schema_admission: :strict,
         work: request.limits.work,
         run_timeout: timeout,
         inherited_deadline: System.system_time(:millisecond) + timeout,
         effect_timeout: min(timeout, request.limits.effect_timeout_ms),
         commit_timeout: min(timeout, request.limits.commit_timeout_ms),
         cleanup_timeout: request.limits.cleanup_timeout_ms,
         output_limit: request.limits.output_limit
       ]}
    else
      {:error, _} = error ->
        error

      _ ->
        failure(
          :resource_conflict,
          "workflow effect child provenance or inherited deadline changed"
        )
    end
  end

  defp child_descriptors?(children, originals, names, binding, identity, ticket) do
    Enum.all?(names, fn name ->
      child = children[name]
      original = originals[name]
      same = Map.delete(child, :backend_context) === Map.delete(original, :backend_context)

      if name in ["exec", "wait"] do
        same and child.backend_context.family === :code_mode and
          child.backend_context.session_binding === binding and
          code_context(child.backend_context.context) ===
            code_context(original.backend_context.context)
      else
        same and
          child.backend_context ===
            original.backend_context
            |> Map.merge(Map.take(identity, @scope))
            |> Map.put(:prepared_target_resolver, ticket.preparation.fetch)
      end
    end)
  end

  defp code_context(context),
    do: Map.drop(context, [:session_binding, :resource_registry, :session_registry])

  defp registered(owned, request, context, locator, deadline) do
    monitors = monitors(owned)
    binding = context.session_binding

    # Registry cleanup runs outside the subscriber task. Publish only the actual
    # native acknowledgement; terminal status alone precedes asynchronous unbind.
    cleanup = fn ->
      if goal_acknowledged?(owned),
        do: cleanup(owned, locator, request.limits.cleanup_timeout_ms, true),
        else: {:uncertain, :workflow_effect_goal_acknowledgement_unconfirmed}
    end

    result =
      case safe(fn ->
             ResourceRegistry.register(
               binding.resource_registry,
               binding.owner_id,
               :workflow_effect,
               %{session: owned.session, headless: owned.headless, locator: locator},
               incarnation: binding.incarnation,
               owner_pid: self(),
               cleanup: cleanup
             )
           end) do
        {:ok, handle} ->
          result =
            safe(fn ->
              with {:ok, ack} <-
                     Headless.execute(owned.headless, @source,
                       input: %{
                         "tool_name" => request.target.tool_name,
                         "arguments" => request.target.arguments
                       }
                     ),
                   true <-
                     ack.run_id === locator.run_id and ack.incarnation === locator.incarnation,
                   {:ok, value} <-
                     Headless.await(owned.headless, timeout: max(0, deadline - now())) do
                {:ok, ack, value}
              else
                {:error, _} = error ->
                  error

                _ ->
                  failure(:unknown_outcome, "workflow effect execution admission is unconfirmed")
              end
            end)

          {result, acknowledged} =
            settle(result, owned, monitors, request, context, locator, deadline)

          cleanup_deadline = now() + request.limits.cleanup_timeout_ms

          goal_cleanup =
            if acknowledged,
              do: :ok,
              else: close_goal(owned, monitors, cleanup_deadline)

          with :ok <- goal_cleanup,
               {:ok, :ok} <-
                 safe(fn ->
                   ResourceRegistry.release(binding.resource_registry, handle, binding.owner_id)
                 end),
               {:ok, %{status: :confirmed}} <-
                 ResourceRegistry.cleanup_status(
                   binding.resource_registry,
                   handle,
                   binding.owner_id
                 ),
               :ok <- down(monitors, cleanup_deadline),
               {:ok, effect} <- result do
            {:ok,
             Map.put(effect, :retirement, %{
               resource_handle: handle,
               release: :confirmed,
               headless: :normal,
               session: :normal,
               registry: :normal
             })}
          else
            {:error, _} = error ->
              error

            _ ->
              failure(
                :unknown_outcome,
                "workflow effect retirement is unconfirmed; do not replay"
              )
          end

        error ->
          startup_error(owned, request, error)
      end

    Enum.each(monitors, fn {_, ref} -> Process.demonitor(ref, [:flush]) end)
    result
  end

  defp settle({:ok, ack, value}, owned, monitors, request, context, locator, deadline) do
    case safe(fn -> goal_terminal(owned, monitors, locator, ack.turn_id, deadline) end) do
      {:ok, :run_completed} ->
        result =
          safe(fn ->
            with {:ok, receipt} <- receipt(owned, request, context, locator, ack, value) do
              {:ok,
               %{
                 request: request,
                 locator: locator,
                 consumer_value: value.value,
                 receipt: receipt
               }}
            end
          end)

        {result, true}

      {:ok, _} ->
        {failure(:unknown_outcome, "workflow effect native Goal run did not complete normally"),
         true}

      error ->
        {error, false}
    end
  end

  defp settle(error, _, _, _, _, _, _), do: {error, false}

  defp goal_terminal(%{goal_binding: nil}, _, _, _, _), do: {:ok, :run_completed}

  defp goal_terminal(owned, monitors, locator, turn_id, deadline) do
    child = owned.headless
    {^child, monitor} = Enum.find(monitors, fn {pid, _} -> pid === child end)
    run_id = locator.run_id
    incarnation = locator.incarnation

    receive do
      {:agent_runtime, ^run_id,
       %{type: type, run_id: ^run_id, incarnation: ^incarnation, turn_id: event_turn}}
      when type in [:run_completed, :run_failed, :run_cancelled] and
             (is_nil(turn_id) or event_turn === turn_id) ->
        acknowledge_goal(owned)
        {:ok, type}

      {:agent_runtime, ^run_id,
       %{type: :storage_failed, run_id: ^run_id, incarnation: ^incarnation}} ->
        failure(:unknown_outcome, "workflow effect native Goal acknowledgement failed")

      {:DOWN, ^monitor, :process, ^child, _} ->
        failure(:unknown_outcome, "workflow effect ended before native Goal acknowledgement")
    after
      max(0, deadline - now()) ->
        failure(:unknown_outcome, "workflow effect native Goal acknowledgement timed out")
    end
  end

  defp goal_acknowledged?(%{goal_binding: nil}), do: true
  defp goal_acknowledged?(owned), do: :atomics.get(owned.goal_ack, 1) === 1

  defp acknowledge_goal(owned), do: :atomics.put(owned.goal_ack, 1, 1)

  defp close_goal(%{goal_binding: nil}, _, _), do: :ok

  defp close_goal(owned, monitors, deadline) do
    safe(fn ->
      with {:ok, %{status: :confirmed}} <-
             Session.close(owned.session, cleanup_deadline: deadline),
           {:ok, type} <-
             goal_terminal(owned, monitors, owned.goal_binding, nil, deadline),
           true <- type in [:run_completed, :run_failed, :run_cancelled] do
        :ok
      else
        _ -> failure(:unknown_outcome, "workflow effect native Goal retirement is unconfirmed")
      end
    end)
  end

  defp receipt(owned, request, context, locator, ack, result) do
    with {:ok, run} <- completed(owned.headless, locator),
         {:ok, aggregate} <- Store.load(context.store, locator.run_id),
         true <- aggregate.run === run and aggregate.incarnation === locator.incarnation,
         true <- aggregate.revision === run.expected_revision,
         true <- result === get_in(run, [:context, :conversation, :headless_result]),
         true <- result.status === :completed and result.nested_invocations === 1,
         intents = Map.values(run.execution_intents),
         [outer] <-
           Enum.filter(intents, fn intent ->
             op = intent.operation

             op.tool_name === "exec" and op.arguments === @source and
               op.enclosing_invocation_id === op.invocation_id
           end),
         true <- intent?(outer, locator, ack, context.caller),
         true <- outer.operation.tool_revision === 1,
         [target] <- Enum.filter(intents, &(&1.operation.tool_name === request.target.tool_name)),
         true <- intent?(target, locator, ack, context.caller),
         true <- target.operation.tool_revision === request.target.tool_revision,
         descriptor = owned.catalog.registry.tools[request.target.tool_name],
         prepared_operation =
           Map.put(
             target.operation,
             :backend_context,
             Map.put(descriptor.backend_context, :catalog_snapshot, owned.catalog)
           ),
         :ok <-
           Filesystem.validate_prepared_receipt(request.target.arguments, prepared_operation),
         true <- target.operation.enclosing_invocation_id === outer.operation.invocation_id,
         true <-
           Enum.all?(
             [:turn_id, :step_id, :attempt_id],
             &(target.operation[&1] === outer.operation[&1])
           ),
         true <- Enum.all?(intents, &(&1.operation.tool_name in selection(request))),
         {:ok, target_result} <- Map.fetch(run.tool_results, target.operation.invocation_id),
         true <- is_map(target_result) and target_result[:is_error] === false,
         false <- Map.has_key?(run.tool_presentations, target.operation.invocation_id),
         %{"revision" => 1, "descriptor_digest" => digest} <- run.context.headless_catalog,
         true <- nonempty?(digest) do
      {:ok,
       %{
         version: 1,
         run_id: locator.run_id,
         incarnation: locator.incarnation,
         turn_id: ack.turn_id,
         catalog_revision: 1,
         catalog_digest: digest,
         outer_intent: outer,
         target_intent: target,
         target_result: target_result,
         target_presentation: nil,
         final_revision: aggregate.revision
       }}
    else
      {:error, _} = error ->
        error

      _ ->
        failure(
          :unknown_outcome,
          "workflow effect exact committed receipt is unconfirmed; do not replay"
        )
    end
  end

  defp intent?(
         %{type: :tool, status: :consumed, operation: op, reservation: reservation},
         locator,
         ack,
         caller
       ) do
    op.run_id === locator.run_id and op.incarnation === locator.incarnation and
      op.turn_id === ack.turn_id and op.caller === caller and op.catalog_revision === 1 and
      Enum.all?(
        [:invocation_id, :tool_call_id, :turn_id, :step_id, :attempt_id],
        &nonempty?(op[&1])
      ) and
      reservation.reservation_id === "tool:" <> op.invocation_id
  end

  defp intent?(_, _, _, _), do: false

  defp completed(child, locator) do
    case Headless.status(child) do
      %{phase: :terminal, resource_cleanup: :confirmed, run: %{state: :completed} = run} ->
        if run.run_id === locator.run_id and run.incarnation === locator.incarnation and
             map_size(Map.get(run, :active_tools, %{})) === 0 and
             is_nil(run[:active_provider]) and is_nil(run[:active_wait]) and
             Map.get(run, :provider_attempts, %{}) === %{},
           do: {:ok, run},
           else: failure(:unknown_outcome, "workflow effect terminal identity is unconfirmed")

      _ ->
        failure(:unknown_outcome, "workflow effect terminal cleanup is unconfirmed")
    end
  end

  defp startup_error(owned, request, error) do
    deadline = now() + request.limits.cleanup_timeout_ms
    observed = monitors(owned)

    goal_cleanup =
      cond do
        is_nil(owned.goal_binding) ->
          :ok

        is_nil(owned.headless) ->
          safe(fn ->
            with %{phase: :reserved} <- Session.status(owned.session),
                 {:ok, :unbound} <- Goal.unbind(owned.goal, owned.goal_binding) do
              acknowledge_goal(owned)
              :ok
            else
              _ ->
                failure(
                  :unknown_outcome,
                  "workflow effect delegated Goal rollback is unconfirmed"
                )
            end
          end)

        true ->
          close_goal(owned, observed, deadline)
      end

    retired =
      if goal_cleanup === :ok,
        do: cleanup(owned, nil, max(0, deadline - now()), false),
        else: {:uncertain, :workflow_effect_goal_acknowledgement_unconfirmed}

    Enum.each(observed, fn {_, ref} -> Process.demonitor(ref, [:flush]) end)

    if goal_cleanup === :ok and retired === :ok do
      error
    else
      failure(:unknown_outcome, "workflow effect startup retirement is unconfirmed")
    end
  end

  defp cleanup(owned, locator, timeout, require_completed) do
    deadline = now() + timeout
    observed = monitors(owned)

    terminal =
      if require_completed,
        do: safe(fn -> completed(owned.headless, locator) end),
        else: {:ok, nil}

    retired =
      safe(fn ->
        with {:ok, %{status: :confirmed}} <-
               Session.close(owned.session, cleanup_deadline: deadline),
             %{phase: :closed, cleanup: {:ok, %{status: :confirmed}}} <-
               Session.status(owned.session),
             :ok <- stop(owned.headless, deadline),
             :ok <- stop(owned.session, deadline),
             :ok <- down(observed, deadline),
             :ok <- release_ticket(owned, deadline) do
          :ok
        else
          _ -> {:uncertain, :workflow_effect_retirement_unconfirmed}
        end
      end)

    Enum.each(observed, fn {_, ref} -> Process.demonitor(ref, [:flush]) end)

    if match?({:ok, _}, terminal) and retired === :ok,
      do: :ok,
      else: {:uncertain, :workflow_effect_terminal_or_retirement_unconfirmed}
  end

  defp release_ticket(%{ticket: nil}, _deadline), do: :ok
  defp release_ticket(%{ticket: ticket}, deadline), do: ticket.release.(deadline)

  defp monitors(owned) do
    for key <- [:headless, :session, :registry],
        pid = owned[key],
        is_pid(pid),
        do: {pid, Process.monitor(pid)}
  end

  defp stop(nil, _), do: :ok

  defp stop(pid, deadline) do
    if deadline > now(),
      do: GenServer.stop(pid, :normal, deadline - now()),
      else: {:uncertain, :workflow_effect_cleanup_deadline}
  end

  defp down([], _), do: :ok

  defp down([{pid, ref} | rest], deadline) do
    receive do
      {:DOWN, ^ref, :process, ^pid, :normal} -> down(rest, deadline)
      {:DOWN, ^ref, :process, ^pid, _} -> {:uncertain, :workflow_effect_abnormal_retirement}
    after
      max(0, deadline - now()) -> {:uncertain, :workflow_effect_retirement_timeout}
    end
  end

  defp evidence({:error, %Error{} = error}, locator, correlation),
    do:
      {:error,
       %{error | details: Map.merge(error.details, %{locator: locator, correlation: correlation})}}

  defp evidence(result, _, _), do: result

  defp safe(function) do
    function.() |> normalize()
  rescue
    _ -> failure(:unknown_outcome, "workflow effect operation raised; do not replay")
  catch
    _, _ -> failure(:unknown_outcome, "workflow effect operation ended; do not replay")
  end

  defp normalize({:error, %Error{}} = error), do: error

  defp normalize({:error, _}),
    do: failure(:unknown_outcome, "workflow effect operation is unconfirmed; do not replay")

  defp normalize(result), do: result
  defp failure(class, message), do: {:error, Error.new(class, message)}

  defp revision(authority, name),
    do: Map.get(Map.get(authority, :tool_revisions, %{}), name, authority[:tool_revision])

  defp selection(request), do: ["exec", "wait", request.target.tool_name]

  defp keys?(value, keys),
    do: is_map(value) and not is_struct(value) and Enum.sort(Map.keys(value)) === Enum.sort(keys)

  defp nonempty?(value),
    do: is_binary(value) and String.valid?(value) and String.trim(value) != ""

  defp json?(value) when is_map(value) and not is_struct(value),
    do:
      Enum.all?(value, fn {key, item} -> is_binary(key) and String.valid?(key) and json?(item) end)

  defp json?(value) when is_list(value), do: Enum.all?(value, &json?/1)
  defp json?(value) when is_binary(value), do: String.valid?(value)
  defp json?(value), do: is_number(value) or is_boolean(value) or is_nil(value)
  defp now, do: System.monotonic_time(:millisecond)
end
