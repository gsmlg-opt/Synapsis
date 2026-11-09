defmodule Synapsis.Agent.Runtime.SessionAdapter do
  @moduledoc "Session-owned root Conversation and nested Backplane collaboration runtime."
  use GenServer

  alias Backplane.AgentRuntime.{Codex, Conversation, Error, Goal, ToolCatalog}
  alias Backplane.AgentRuntime.Codex.{MultiAgent, Session}

  alias Synapsis.Agent.Runtime.{
    GoalLifecycle,
    GoalStore,
    ProviderAdapter,
    ProviderMessages,
    RunInventory,
    Store
  }

  alias Synapsis.Runtime.Store, as: Journal
  alias Synapsis.Session.Worker.{Config, GoalHost}

  alias Synapsis.Agent.Tools.{
    Approval,
    Browser,
    CodeMode,
    Discovery,
    Filesystem,
    FilesystemResultContract,
    MCPResources,
    NativeLocal,
    Policy,
    Profiles,
    ProcessInspection,
    SkillBodyCache,
    SkillResultContract,
    Questions
  }

  alias Synapsis.Agent.Tools.Web.{Fetch, Search}

  @collaboration ~w(spawn_agent send_message followup_task interrupt_agent list_agents wait_agent)
  @terminal [:run_completed, :run_failed, :run_cancelled]
  @settled [:completed, :errored, :interrupted, :closed, :shutdown]
  @filesystem_names Filesystem.names()
  @filesystem_identity_fields ~w(run_id incarnation catalog_revision invocation_id tool_name tool_revision turn_id step_id attempt_id tool_call_id)a
  @filesystem_correlation_fields ~w(turn_id step_id attempt_id tool_call_id)a
  @filesystem_candidate_fields ~w(original_path public_path source_path requested_absolute target source_prefix)a
  @prepared_target_limit 1_024
  @prepared_target_bytes_limit 16 * 1_024 * 1_024
  @prepared_target_record_limit 64 * 1_024

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def prompt(pid, context, content), do: GenServer.cast(pid, {:prompt, context, content})
  def input(pid, content), do: GenServer.cast(pid, {:input, content})
  def cancel(pid), do: GenServer.cast(pid, :cancel)
  def resolve(pid, id, decision), do: GenServer.cast(pid, {:resolve, id, decision})

  def answer_question(pid, id, response),
    do: GenServer.cast(pid, {:answer_question, id, response})

  def snapshot(pid), do: GenServer.call(pid, :snapshot)

  @doc "Read the current native root identity without reading or mutating its history."
  def automation_snapshot(pid, timeout \\ 5_000),
    do: GenServer.call(pid, :automation_snapshot, timeout)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(opts, :owner)
    id = Keyword.fetch!(opts, :session_id)
    {:ok, store} = Store.new(1)

    state =
      %{
        owner: owner,
        owner_ref: Process.monitor(owner),
        session_id: id,
        adapter: self(),
        epoch: Keyword.fetch!(opts, :epoch),
        provider: Keyword.get(opts, :provider, ProviderAdapter),
        fixture_context: Keyword.get(opts, :provider_context, %{}),
        limit: Keyword.get(opts, :max_concurrent_threads_per_session, 4),
        goal: nil,
        goal_binding: nil,
        goal_recovery: %{diagnostic: :none},
        session: nil,
        manager: nil,
        binding: nil,
        collaboration_descriptors: [],
        child_sessions: %{},
        browser_resources: %{},
        mcp_resource_runtimes: %{},
        local_runtime: nil,
        tool_contexts: %{},
        discovery_cleanup: %{},
        store: store,
        root: nil,
        context: nil,
        run_id: nil,
        runs: %{},
        jobs: %{},
        pending: %{},
        roster: %{agents: [], admissions: []},
        initializing: true,
        queued_prompt: nil,
        recovery_inventory: nil,
        busy: false,
        closing: false,
        terminal_failure: nil,
        error: :initializing
      }

    {:ok, job(state, :recovery_loaded, fn -> load_goal_recovery(state) end)}
  end

  @impl true
  def handle_call(:automation_snapshot, _from, state),
    do: {:reply, Map.take(state, [:root, :run_id, :epoch]), state}

  def handle_call(:snapshot, _from, state),
    do:
      {:reply,
       Map.put(
         state.roster,
         :pending,
         Enum.map(state.pending, fn {id, x} -> Map.put(x.request, :interaction_id, id) end)
       ), state}

  def handle_call({:tool_context, identity, catalog}, _from, state) do
    key = {identity[:run_id], identity[:incarnation]}

    result =
      case Map.get(state.tool_contexts, key) do
        %{snapshot: _} = entry ->
          project_skill_catalog(entry, identity, catalog)

        nil ->
          failure(:forbidden, "Tool catalog context is unavailable or stale")
      end

    {:reply, result, state}
  end

  def handle_call({:skill_successor_context, operation, catalog}, _from, state) do
    key = {operation[:run_id], operation[:incarnation]}

    result =
      with %{skill_context: context, skill_ceiling: ceiling} = entry <- state.tool_contexts[key],
           {:ok, issued} <- project_skill_catalog(entry, operation, catalog),
           {:ok, %{descriptor: %{backend: Synapsis.Agent.Tools.SkillWorkshop}}} <-
             Profiles.preparation_binding(operation, issued) do
        {:ok, issued, context, state.binding, ceiling}
      else
        _ -> failure(:forbidden, "Skill successor has no matching producer catalog")
      end

    {:reply, result, state}
  end

  def handle_call(
        {:skill_successor_register, operation, predecessor, update, prepared},
        _from,
        state
      ) do
    key = {operation[:run_id], operation[:incarnation]}

    with %{snapshot: _} = entry <- state.tool_contexts[key],
         {:ok, issued} <- project_skill_catalog(entry, operation, predecessor),
         {:ok, %{descriptor: %{backend: Synapsis.Agent.Tools.SkillWorkshop}}} <-
           Profiles.preparation_binding(operation, issued),
         {:ok, expected} <-
           ToolCatalog.validate(update, predecessor.revision, %{
             run_id: operation.run_id,
             incarnation: operation.incarnation
           }),
         {:ok, _} <-
           Profiles.project_catalog(
             %{
               run_id: operation.run_id,
               incarnation: operation.incarnation,
               catalog_revision: expected.revision
             },
             prepared.snapshot,
             expected
           ) do
      successor = %{
        revision: expected.revision,
        publication_id: expected.publication_id,
        predecessor: predecessor,
        producer_invocation_id: operation.invocation_id,
        snapshot: prepared.snapshot,
        discovery: prepared.discovery,
        skill_body_cache: prepared.skill_body_cache
      }

      next = Map.update(entry, :skill_successors, [successor], &(&1 ++ [successor]))
      {:reply, :ok, put_in(state, [:tool_contexts, key], next)}
    else
      _ ->
        {:reply, failure(:forbidden, "Skill successor evidence does not match its producer"),
         state}
    end
  end

  def handle_call({:filesystem_target_reserve, identity, catalog, digest}, {producer, _}, state) do
    with {:ok, context_key, entry, key, correlation, _descriptor} <-
           filesystem_target_context(state, identity, catalog),
         true <- filesystem_digest?(digest) and is_pid(producer) and Process.alive?(producer) do
      case entry.prepared_targets[key] do
        nil ->
          if map_size(entry.prepared_targets) < @prepared_target_limit do
            envelope = %{
              state: :reserved,
              token: make_ref(),
              producer_pid: producer,
              monitor: Process.monitor(producer),
              raw_arguments_digest: digest,
              correlation: correlation,
              record: nil
            }

            case put_prepared_target(state, context_key, entry, key, envelope) do
              {:ok, reserved} ->
                {:reply, {:ok, {:new, envelope.token}}, reserved}

              {:error, _} = error ->
                Process.demonitor(envelope.monitor, [:flush])
                {:reply, error, state}
            end
          else
            {:reply, {:error, :prepared_target_limit}, state}
          end

        %{state: :sealed, correlation: ^correlation, record: record}
        when digest == record.raw_arguments_digest or digest == record.prepared_arguments_digest ->
          {:reply, {:ok, {:existing, record}}, state}

        _ ->
          {:reply, {:error, :prepared_target_conflict}, state}
      end
    else
      false -> {:reply, {:error, :invalid_prepared_target}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call(
        {:filesystem_target_seal, identity, catalog, token, candidate, digest},
        {producer, _},
        state
      ) do
    with {:ok, context_key, entry, key, correlation, descriptor} <-
           filesystem_target_context(state, identity, catalog),
         true <- filesystem_digest?(digest) and is_reference(token) and is_pid(producer),
         %{state: phase, token: ^token, producer_pid: ^producer, correlation: ^correlation} =
           envelope <- entry.prepared_targets[key],
         true <- phase in [:reserved, :sealed] and Process.alive?(producer),
         {:ok, record} <-
           filesystem_target_record(identity, descriptor, key, envelope, candidate, digest) do
      case envelope do
        %{state: :sealed, record: ^record} ->
          {:reply, {:ok, record}, state}

        %{state: :reserved} ->
          sealed = %{envelope | state: :sealed, record: record}

          case put_prepared_target(state, context_key, entry, key, sealed) do
            {:ok, sealed_state} -> {:reply, {:ok, record}, sealed_state}
            {:error, _} = error -> {:reply, error, state}
          end

        _ ->
          {:reply, {:error, :prepared_target_conflict}, state}
      end
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :prepared_target_conflict}, state}
    end
  end

  def handle_call({:filesystem_target_fetch, identity, catalog, digest}, _from, state) do
    result =
      with {:ok, _context_key, entry, key, correlation, _descriptor} <-
             filesystem_target_context(state, identity, catalog),
           true <- filesystem_digest?(digest),
           %{state: :sealed, correlation: ^correlation, record: record} <-
             entry.prepared_targets[key],
           true <- record.prepared_arguments_digest === digest do
        {:ok, record}
      else
        {:error, _} = error -> error
        _ -> {:error, :prepared_target_unavailable}
      end

    {:reply, result, state}
  end

  def handle_call({:filesystem_target_abandon, identity, catalog, token}, {producer, _}, state) do
    with {:ok, context_key, entry, key, correlation, _descriptor} <-
           filesystem_target_context(state, identity, catalog),
         true <- is_reference(token) and is_pid(producer) and Process.alive?(producer),
         %{state: phase, token: ^token, producer_pid: ^producer, correlation: ^correlation} =
           envelope <- entry.prepared_targets[key],
         true <- phase in [:reserved, :abandoned] do
      demonitor_prepared_target(envelope)
      abandoned = %{envelope | state: :abandoned, monitor: nil}
      {:ok, abandoned_state} = put_prepared_target(state, context_key, entry, key, abandoned)
      {:reply, :ok, abandoned_state}
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :prepared_target_conflict}, state}
    end
  end

  def handle_call({:child_options, request, run_id, parent}, from, state) do
    if state.closing or state.error do
      {:reply, failure(:resource_conflict, "Subagent admission is closed"), state}
    else
      with %{context: %{mode_provenance: mode_provenance} = caller_context} <-
             state.runs[parent.run_id],
           true <- parent[:goal] == state.goal,
           {:ok, parent_attribution} <- Goal.attribution(state.goal, parent.goal_binding) do
        identity = parent.child

        previous =
          Enum.find_value(state.runs, fn {_id, run} ->
            if run.identity[:agent_id] == identity.agent_id, do: run.context
          end)

        parent_context =
          (previous || caller_context)
          |> Map.put(:mode_provenance, mode_provenance)
          |> Map.put(:input_context, nil)

        intent =
          Map.merge(identity, %{
            parent_name: parent.name,
            parent_run_id: parent.run_id,
            namespace: state.store.namespace
          })

        locator =
          RunInventory.child(
            state.session_id,
            state.store,
            identity,
            parent.run_id,
            mode_provenance
          )

        tag = {:child_prepare, from, request, run_id, parent, parent_context, intent}

        attribution =
          GoalLifecycle.child_fact(
            state.session_id,
            state.store,
            identity,
            parent_attribution,
            mode_provenance
          )

        {:noreply,
         job(state, tag, fn ->
           with :ok <-
                  Journal.put_fact(
                    state.session_id,
                    :admission_intent,
                    identity.attempt_id,
                    intent
                  ),
                :ok <- RunInventory.retain(locator),
                :ok <- GoalLifecycle.retain(attribution),
                do: :ok
         end)}
      else
        _ ->
          {:reply, failure(:resource_conflict, "Parent run context is unavailable"), state}
      end
    end
  end

  def handle_call({:receipt, receipt}, _from, state) do
    result =
      Journal.put_fact(
        state.session_id,
        :admission_receipt,
        receipt.attempt_id <> ":" <> to_string(receipt.status),
        receipt
      )

    case result do
      :ok ->
        state =
          case state.child_sessions[receipt.agent_id] do
            %{identity: identity, binding: binding}
            when receipt.status == :rejected and not receipt.process_started and
                   identity.attempt_id == receipt.attempt_id and
                   identity.run_id == receipt.run_id and
                   identity.incarnation == receipt.incarnation ->
              discard_child_reservation(state, identity, binding)

            _ ->
              state
          end

        {:reply, :ok, state}

      _ ->
        {:reply, failure(:execution_failure, "Subagent admission receipt could not be persisted"),
         %{state | error: :storage_failed}}
    end
  end

  @impl true
  def handle_cast({:prompt, context, content}, %{initializing: true} = state) do
    if state.queued_prompt || state.closing do
      notify(state, {:runtime_admission_failed, state.epoch, :runtime_busy})
      {:noreply, state}
    else
      {:noreply, %{state | queued_prompt: {context, content}}}
    end
  end

  def handle_cast({:prompt, context, content}, state) do
    if state.busy or state.closing or state.error do
      notify(state, {:runtime_roster, state.epoch, state.roster})
      notify(state, {:runtime_admission_failed, state.epoch, state.error || :runtime_busy})
      {:noreply, state}
    else
      case Config.mode_provenance(context.session) do
        {:ok, mode_provenance} ->
          context = Map.put(context, :mode_provenance, mode_provenance)
          run_id = Ecto.UUID.generate()
          state = %{state | busy: true, context: context, run_id: run_id}

          {:noreply,
           job(state, :prepare_inputs, fn ->
             prepare(self_host(state), state, context, run_id, content)
           end)}

        {:error, reason} ->
          notify(state, {:runtime_admission_failed, state.epoch, reason})
          {:noreply, state}
      end
    end
  end

  def handle_cast({:input, content}, state) do
    {:noreply,
     if(is_pid(state.root),
       do: job(state, :input, fn -> Conversation.steer(state.root, content) end),
       else: state
     )}
  end

  def handle_cast({:resolve, id, decision}, state) do
    case Map.get(state.pending, id) do
      %{request: request, run_id: run_id, destination: destination}
      when is_boolean(decision) ->
        scope = request_field(request, :scope)
        operation = request_field(request, :operation)

        if is_map(scope) and is_map(operation) and
             request_field(scope, :session_id) === state.session_id and
             request_field(scope, :requester_id) === Approval.operator_id() and
             request_field(operation, :run_id) === run_id and not state.closing do
          answer = if decision, do: :approved, else: :denied
          trusted = %{scope: scope, operation: operation}

          {:noreply,
           job(state, {:resolve, id}, fn ->
             case destination do
               {:root, pid} ->
                 Approval.resolve(pid, id, answer, trusted)

               {:managed, manager, correlation} ->
                 Approval.resolve_managed(manager, correlation, answer, trusted)
             end
           end)}
        else
          finish_job({:resolve, id}, failure(:forbidden, "Approval scope is unavailable"), state)
        end

      _ ->
        finish_job({:resolve, id}, failure(:forbidden, "Approval is no longer available"), state)
    end
  end

  def handle_cast({:answer_question, id, response}, state) do
    case Map.get(state.pending, id) do
      %{
        request: %{kind: :user_question, scope: scope, operation: operation},
        run_id: run_id,
        destination: {:root, pid}
      }
      when is_binary(response) and not state.closing ->
        if scope.session_id === state.session_id and operation.run_id === run_id do
          {:noreply,
           job(state, {:resolve, id}, fn ->
             Questions.resolve(pid, id, response, %{scope: scope, operation: operation})
           end)}
        else
          finish_job({:resolve, id}, failure(:forbidden, "Question scope is unavailable"), state)
        end

      _ ->
        finish_job({:resolve, id}, failure(:forbidden, "Question is no longer available"), state)
    end
  end

  def handle_cast(:cancel, state), do: {:noreply, close(state)}

  @impl true
  def handle_info({:job_result, ref, result}, state) do
    case Map.pop(state.jobs, ref) do
      {nil, _} ->
        {:noreply, state}

      {{pid, monitor, tag}, jobs} ->
        Process.demonitor(monitor, [:flush])
        Process.unlink(pid)
        finish_job(tag, result, %{state | jobs: jobs})
    end
  end

  def handle_info({:agent_runtime, run_id, event}, state) do
    cond do
      run_id != state.run_id ->
        {:noreply, state}

      event.type in @terminal and (state.closing or not state.busy) ->
        {:noreply, state}

      event.type in @terminal ->
        state =
          close_prepared_targets(state, if(event.type == :run_completed, do: run_id, else: :all))

        # Loading committed history never calls the collaboration manager.
        state =
          if event.type == :run_completed,
            do: state,
            else: %{
              state
              | child_sessions:
                  Map.new(state.child_sessions, fn {id, child} ->
                    {id, %{child | closing: true}}
                  end)
            }

        {:noreply,
         job(state, {:terminal, event}, fn ->
           status = Conversation.status(state.root)
           stop(state.root, owner_stop_timeout(state))

           status =
             Map.put(status, :discovery_cleanup, release_discovery(state.tool_contexts, run_id))

           if event.type == :run_completed,
             do: status,
             else: Map.put(status, :cleanup, close_sessions(state))
         end)}

      event.type == :interaction_requested ->
        {:noreply, remember_permission(state, {:root, state.root}, run_id, event)}

      event.type == :interaction_resolved ->
        {:noreply, forget_permission(state, event.interaction_id)}

      true ->
        notify(state, {:runtime_event, state.epoch, run_id, event})
        {:noreply, state}
    end
  end

  def handle_info({:codex_collaboration, event}, state) do
    roster =
      state.roster |> Map.put(:manager_id, event.manager_id) |> Map.put(:revision, event.revision)

    roster =
      if event[:agent],
        do: Map.update(roster, :agents, [event.agent], &upsert(&1, event.agent, :agent_id)),
        else: roster

    roster =
      if event[:admission],
        do:
          Map.update(
            roster,
            :admissions,
            [event.admission],
            &upsert(&1, event.admission, :attempt_id)
          ),
        else: roster

    state = persist_roster(%{state | roster: roster})

    state =
      case event do
        %{type: :interaction_requested, agent: %{pending_interaction: pending} = agent}
        when is_map(pending) ->
          remember_permission(
            state,
            {:managed, state.manager, pending.correlation},
            agent.run_id,
            %{type: :interaction_requested, interaction_id: pending.id, request: pending.request}
          )

        %{type: :interaction_resolved, interaction_id: id} ->
          forget_permission(state, id)

        _ ->
          state
      end

    state =
      if event[:agent] && event.agent.status in @settled,
        do: forget_run_permissions(state, event.agent.run_id),
        else: state

    state =
      if event[:agent] && event.agent.status in @settled,
        do:
          state
          |> close_prepared_targets(event.agent.run_id)
          |> cleanup_discovery(event.agent.run_id),
        else: state

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when ref == state.owner_ref,
    do: {:stop, :normal, close_prepared_targets(%{state | error: {:owner_down, reason}}, :all)}

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    state = settle_prepared_target_producer(state, ref, pid)

    case Enum.find(state.jobs, fn {_key, {_pid, monitor, _tag}} -> monitor == ref end) do
      {key, {_pid, _monitor, tag}} ->
        finish_job(
          tag,
          failure(:unknown_outcome, "Runtime operation exited: #{inspect(reason)}"),
          %{state | jobs: Map.delete(state.jobs, key)}
        )

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, pid, reason}, state) do
    local = if state.local_runtime, do: state.local_runtime.server

    child_lost =
      Enum.any?(state.child_sessions, fn {_id, child} ->
        child.session == pid and not child.closing and not state.closing and
          state.error != :closed
      end)

    if child_lost or (pid == state.goal and not state.closing) or
         (pid in [state.session, state.manager, state.root, local] and
            reason not in [:normal, :shutdown]) do
      state = persist_roster(%{state | roster: unknown(state.roster), error: :runtime_owner_lost})

      notify(
        state,
        {:runtime_event, state.epoch, state.run_id,
         %{type: :storage_failed, error: :runtime_owner_lost}}
      )

      {:noreply, close(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state = close_prepared_targets(state, :all)
    Enum.each(state.jobs, fn {_ref, {pid, _, _}} -> Process.exit(pid, :kill) end)
    # Session and manager termination fence their owned effects and children;
    # no journal record is ever used to replay an interrupted effect.
    Enum.each([state.root, state.session, state.manager], &stop(&1, owner_stop_timeout(state)))
    close_child_sessions(state)
    if state.local_runtime, do: stop(state.local_runtime.server)
    stop(state.goal)

    if state.busy or Enum.any?(state.roster[:agents] || [], &(&1.status not in @settled)),
      do: Journal.put_projection(state.session_id, unknown(state.roster))

    :ok
  end

  defp load_goal_recovery(state) do
    with {:ok, recovered} <- recover(state.session_id),
         {:ok, facts} <- Journal.list_facts(state.session_id, :goal_attribution),
         {:ok, goal} <-
           Goal.start_link(
             thread_id: state.session_id,
             owner_pid: state.adapter,
             store: GoalStore,
             store_context: :local,
             host: GoalHost,
             host_context: %{
               owner: state.owner,
               adapter: state.adapter,
               epoch: state.epoch,
               session_id: state.session_id
             }
           ) do
      Process.unlink(goal)
      {:ok, Map.merge(recovered, %{goal: goal, attributions: facts})}
    end
  end

  defp recover(id) do
    saved =
      case Journal.get_projection(id) do
        {:ok, value} -> {:ok, value}
        :not_found -> {:ok, %{agents: [], admissions: []}}
        error -> error
      end

    with {:ok, saved} <- saved,
         {:ok, intents} <- Journal.list_facts(id, :admission_intent),
         {:ok, receipts} <- Journal.list_facts(id, :admission_receipt),
         {:ok, inventory} <- RunInventory.load(id) do
      unresolved =
        Enum.any?(intents, fn intent ->
          not Enum.any?(receipts, &(&1.attempt_id == intent.attempt_id))
        end) or
          Enum.any?(receipts, fn receipt ->
            receipt.process_started and
              not Enum.any?(saved[:agents] || [], &(&1.agent_id == receipt.agent_id))
          end)

      structural_uncertain =
        unresolved or Enum.any?(saved[:agents] || [], &(&1.status not in @settled)) or
          (is_map(saved[:root]) and saved.root.status not in @settled)

      {:ok, %{saved: saved, inventory: inventory, structural_uncertain: structural_uncertain}}
    else
      {:error, reason} ->
        {:error,
         Error.new(:execution_failure, "Runtime recovery inventory could not be loaded",
           details: %{reason: reason}
         )}
    end
  end

  defp finalize_goal_recovery(id, recovered) do
    with {:ok, inventory} <- RunInventory.load(id) do
      uncertain =
        recovered.structural_uncertain or Enum.any?(inventory.entries, &unsettled_inventory?/1)

      roster = if uncertain, do: unknown(recovered.saved), else: recovered.saved

      roster =
        roster
        |> Map.put(:recovery_required, uncertain)
        |> Map.update(:agents, [], fn agents ->
          Enum.map(agents, &Map.merge(&1, %{historical: true, resident: false}))
        end)

      with :ok <- if(uncertain, do: Journal.put_projection(id, roster), else: :ok),
           do: {:ok, %{roster: roster, inventory: inventory, uncertain: uncertain}}
    end
  end

  defp unsettled_inventory?(%{availability: :absent}), do: true

  defp unsettled_inventory?(%{aggregate: aggregate}) do
    aggregate.run.state not in [:completed, :failed, :cancelled, :timed_out] or
      get_in(aggregate, [:run, :context, :conversation, :goal_outbox]) not in [nil, []]
  end

  defp self_host(state), do: state.adapter

  defp job(state, tag, fun) do
    host = self()
    ref = make_ref()

    {pid, monitor} =
      :erlang.spawn_opt(fn -> send(host, {:job_result, ref, safe(fun)}) end, [:link, :monitor])

    Map.update!(state, :jobs, &Map.put(&1, ref, {pid, monitor, tag}))
  end

  defp safe(fun) do
    fun.()
  rescue
    exception -> failure(:execution_failure, Exception.message(exception))
  catch
    :exit, reason -> failure(:unknown_outcome, "Runtime owner unavailable: #{inspect(reason)}")
  end

  defp finish_job(:recovery_loaded, {:ok, recovered}, state) do
    Process.link(recovered.goal)
    state = %{state | goal: recovered.goal}

    if recovered.structural_uncertain or
         Enum.any?(recovered.inventory.entries, fn entry ->
           entry.availability != :present or
             entry.aggregate.run.state not in [:completed, :failed, :cancelled, :timed_out]
         end) do
      # Retained terminal receipts do not settle another unresolved/live run.
      continue_goal_recovery(state, [], recovered)
    else
      with {:ok, record} <- Goal.snapshot(state.goal),
           {:ok, groups} <-
             GoalLifecycle.plan(recovered.inventory, recovered.attributions, record) do
        continue_goal_recovery(state, groups, recovered)
      else
        {:error, error} -> finish_job(:recover, {:error, error}, state)
      end
    end
  end

  defp finish_job(:recovery_loaded, {:error, error}, state),
    do: finish_job(:recover, {:error, error}, state)

  defp finish_job({:goal_recovery, remaining, recovered}, {:ok, _aggregate}, state),
    do: continue_goal_recovery(state, remaining, recovered)

  defp finish_job({:goal_recovery, _, _}, {:error, error}, state),
    do: finish_job(:recover, {:error, error}, state)

  defp finish_job(:recover, {:ok, recovered}, state) do
    queued = state.queued_prompt

    state = %{
      state
      | initializing: false,
        queued_prompt: nil,
        roster: recovered.roster,
        recovery_inventory: recovered.inventory,
        goal_recovery: %{
          diagnostic: if(recovered.uncertain, do: :recovery_required, else: :none)
        },
        error: if(recovered.uncertain, do: :recovery_required)
    }

    notify(state, {:runtime_roster, state.epoch, state.roster})

    cond do
      state.closing ->
        {:noreply, cancelled_without_runtime(state)}

      queued && state.error ->
        notify(state, {:runtime_admission_failed, state.epoch, state.error})
        {:noreply, state}

      queued ->
        {context, content} = queued
        handle_cast({:prompt, context, content}, state)

      true ->
        {:noreply, state}
    end
  end

  defp finish_job(:recover, {:error, error}, state) do
    state = %{
      state
      | initializing: false,
        queued_prompt: nil,
        goal_recovery: %{diagnostic: :recovery_required},
        roster: unknown(state.roster),
        error: :storage_failed
    }

    notify(state, {:runtime_roster, state.epoch, state.roster})
    notify(state, {:runtime_admission_failed, state.epoch, error})
    {:noreply, state}
  end

  defp finish_job(:prepare_inputs, {:ok, runtime}, state) do
    Enum.each([runtime.session, runtime.manager], &Process.link/1)
    if runtime.local_runtime, do: Process.link(runtime.local_runtime.server)

    state =
      Map.merge(
        state,
        Map.take(runtime, [
          :session,
          :manager,
          :binding,
          :collaboration_descriptors,
          :local_runtime
        ])
      )

    attrs = %{
      thread_id: state.session_id,
      run_id: state.run_id,
      incarnation: 1,
      mode: state.context.mode_provenance.mode,
      authority: Keyword.fetch!(runtime.options, :authority),
      usage_authoritative: false
    }

    if state.closing or state.error do
      {:error, error} = failure(:resource_conflict, "Runtime preparation is closed")
      discard_prepared_root(state, error, nil)
    else
      with {:ok, binding, attribution} <- bind_root_goal(state.goal, attrs) do
        fact =
          GoalLifecycle.root_fact(
            state.session_id,
            state.store,
            attribution,
            state.context.mode_provenance
          )

        state = %{state | goal_binding: binding}

        {:noreply,
         job(state, :prepare, fn ->
           result =
             safe(fn ->
               with :ok <- GoalLifecycle.retain(fact),
                    {:ok, root} <-
                      Conversation.start_link(
                        Keyword.merge(runtime.options,
                          subscriber: state.adapter,
                          session_binding: runtime.binding,
                          thread_id: state.session_id,
                          goal: state.goal,
                          goal_binding: binding
                        )
                      ) do
                 Process.unlink(root)
                 {:ok, Map.put(runtime, :root, root)}
               end
             end)

           case result do
             {:error, error} -> cleanup_prepared_root(state, error, binding)
             success -> success
           end
         end)}
      else
        {:error, error, binding} -> discard_prepared_root(state, error, binding)
      end
    end
  end

  defp finish_job(:prepare_inputs, {:error, error}, state),
    do: finish_job(:prepare, {:error, error}, state)

  defp finish_job({:child_prepare, from, request, run_id, parent, context, intent}, :ok, state) do
    {reply, state} =
      if state.closing or state.error do
        {failure(:resource_conflict, "Subagent admission is closed"), state}
      else
        {:reply, reply, state} = prepared_child(request, run_id, parent, context, intent, state)
        {reply, state}
      end

    GenServer.reply(from, reply)
    {:noreply, state}
  end

  defp finish_job({:child_prepare, from, _, _, _, _, _}, {:error, reason}, state) do
    error =
      Error.new(:execution_failure, "Subagent run address could not be persisted",
        details: %{reason: reason}
      )

    GenServer.reply(from, {:error, error})
    {:noreply, %{state | error: :storage_failed}}
  end

  defp finish_job(:prepare, {:ok, runtime}, state) do
    Enum.each([runtime.session, runtime.manager, runtime.root], &Process.link/1)
    if runtime.local_runtime, do: Process.link(runtime.local_runtime.server)

    state =
      Map.merge(
        state,
        Map.take(runtime, [
          :session,
          :manager,
          :root,
          :binding,
          :collaboration_descriptors,
          :local_runtime
        ])
      )

    state = %{
      state
      | browser_resources: merge_browser_resources(state.browser_resources, runtime),
        mcp_resource_runtimes: merge_mcp_resource_runtimes(state.mcp_resource_runtimes, runtime),
        tool_contexts: Map.put(state.tool_contexts, runtime.metadata.key, runtime.metadata.entry)
    }

    # Preparation can finish after close has already fenced the adapter.
    state =
      if state.closing or state.error,
        do: close_prepared_targets(state, :all),
        else: state

    state = %{
      state
      | runs:
          Map.put(state.runs, state.run_id, %{
            identity: %{name: "/root"},
            store: state.store,
            context: state.context
          })
    }

    state = project_root(state, :running)

    cond do
      state.error == :storage_failed ->
        state = close_prepared_targets(state, :all)

        {:noreply,
         job(state, :admission_failure_close, fn ->
           result = close_sessions(state)
           Enum.each([state.root, state.manager, state.session], &stop/1)
           result
         end)}

      state.closing ->
        {:noreply, close(%{state | closing: false})}

      true ->
        notify(state, {:runtime_started, state.epoch, state.run_id})

        {:noreply,
         job(state, :prompt, fn -> Conversation.prompt(state.root, runtime.content) end)}
    end
  end

  defp finish_job(
         :prepare,
         {:error, %Error{class: :unknown_outcome} = error},
         %{closing: true} = state
       ),
       do: finish_job(:close, {:error, error}, state)

  defp finish_job(:prepare, {:error, error}, state) do
    if state.closing do
      {:noreply, cancelled_without_runtime(state)}
    else
      notify(state, {:runtime_admission_failed, state.epoch, error})
      {:noreply, %{state | busy: false, error: :admission_failed}}
    end
  end

  defp finish_job(:admission_failure_close, result, state) do
    state = close_prepared_targets(state, :all)

    class =
      if match?({:ok, %{status: :confirmed}}, result),
        do: :execution_failure,
        else: :unknown_outcome

    {:error, error} = failure(class, "Runtime ownership projection could not be persisted")
    notify(state, {:runtime_admission_failed, state.epoch, error})
    {:noreply, %{state | busy: false, root: nil, manager: nil, session: nil}}
  end

  # Closing owns the terminal boundary, including canonical history. A status
  # job that was already in flight must not publish or alter the settled root.
  defp finish_job({:terminal, _}, _, %{closing: true} = state), do: {:noreply, state}
  defp finish_job({:terminal, _}, _, %{busy: false} = state), do: {:noreply, state}

  defp finish_job({:terminal, event}, %{messages: messages} = status, state) do
    root_status =
      cond do
        event[:state] == :unknown_outcome -> :unknown_outcome
        event.type == :run_completed -> :completed
        match?({:ok, %{status: :confirmed}}, status[:cleanup]) -> :errored
        true -> :unknown_outcome
      end

    state = record_discovery_cleanup(state, Map.get(status, :discovery_cleanup, %{}))
    state = project_root(state, root_status)
    notify(state, {:runtime_history, state.epoch, state.run_id, messages})
    event = event |> Map.put(:messages, messages) |> Map.put(:cleanup, status[:cleanup])
    event = if status[:error], do: Map.put(event, :error, status.error), else: event
    state = %{state | root: nil}

    cond do
      state.error == :storage_failed ->
        notify(state, {:runtime_event, state.epoch, state.run_id, %{type: :storage_failed}})
        {:noreply, close(state)}

      true ->
        if not state.closing,
          do: notify(state, {:runtime_event, state.epoch, state.run_id, event})

        state =
          if event.type != :run_completed,
            do: %{
              state
              | error: if(root_status == :errored, do: :closed, else: :cleanup_unconfirmed)
            },
            else: state

        {:noreply,
         %{
           state
           | busy: false,
             pending: Map.reject(state.pending, fn {_, item} -> item.run_id == state.run_id end)
         }}
    end
  end

  defp finish_job({:discovery_cleanup, _run_id}, results, state) when is_map(results),
    do: {:noreply, record_discovery_cleanup(state, results)}

  defp finish_job({:resolve, id}, :ok, state) do
    {:noreply, forget_permission(state, id)}
  end

  defp finish_job({:child_cleanup, agent_id, binding}, result, state) do
    state =
      case state.child_sessions[agent_id] do
        %{binding: ^binding} = child ->
          put_in(state, [:child_sessions, agent_id], %{child | cleanup: result})

        _ ->
          state
      end

    {:noreply, state}
  end

  defp finish_job(:close, %{cleanup: result, history: history}, state) do
    state = close_prepared_targets(state, :all)
    failed = state.terminal_failure

    uncertain =
      state.error == :runtime_owner_lost or state.roster[:recovery_required] == true or
        get_in(state.roster, [:root, :status]) == :unknown_outcome

    state = %{state | closing: false, busy: false, pending: %{}, root: nil, error: :closed}

    state =
      if match?({:ok, %{status: :confirmed}}, result) and not uncertain,
        do: project_root(state, if(failed, do: :errored, else: :closed)),
        else:
          persist_roster(%{state | roster: unknown(state.roster), error: :cleanup_unconfirmed})

    event = %{type: if(failed, do: :run_failed, else: :run_cancelled), cleanup: result}
    event = if failed, do: Map.put(event, :error, failed), else: event

    {state, event} =
      case history do
        {:ok, messages} ->
          notify(state, {:runtime_history, state.epoch, state.run_id, messages})
          {state, Map.put(event, :messages, messages)}

        {:error, error} ->
          roster = state.roster |> unknown() |> Map.put(:recovery_required, true)

          state =
            project_root(%{state | roster: roster, error: :storage_failed}, :unknown_outcome)

          {state, %{type: :storage_failed, error: error, cleanup: result}}
      end

    event = if state.error == :storage_failed, do: %{event | type: :storage_failed}, else: event
    notify(state, {:runtime_event, state.epoch, state.run_id, event})
    {:noreply, state}
  end

  defp finish_job(:close, {:error, error}, state) do
    state = close_prepared_targets(state, :all)

    state =
      persist_roster(%{
        state
        | closing: false,
          busy: false,
          pending: %{},
          roster: unknown(state.roster),
          error: :cleanup_unconfirmed
      })

    notify(
      state,
      {:runtime_event, state.epoch, state.run_id, %{type: :storage_failed, error: error}}
    )

    {:noreply, state}
  end

  defp finish_job(tag, {:error, error}, state)
       when tag == :prompt or (is_tuple(tag) and elem(tag, 0) == :terminal) do
    if state.closing or not state.busy,
      do: {:noreply, state},
      else: {:noreply, close(%{state | terminal_failure: error})}
  end

  defp finish_job(_tag, {:error, error}, state) do
    notify(
      state,
      {:runtime_event, state.epoch, state.run_id,
       %{type: :runtime_operation_failed, error: error}}
    )

    {:noreply, state}
  end

  defp finish_job(_tag, _, state), do: {:noreply, state}

  defp bind_root_goal(goal, attrs) do
    case safe(fn -> Goal.bind(goal, attrs) end) do
      {:ok, binding} ->
        case safe(fn -> Goal.attribution(goal, binding) end) do
          {:ok, attribution} -> {:ok, binding, attribution}
          {:error, error} -> {:error, error, binding}
        end

      {:error, error} ->
        {:error, error, nil}
    end
  end

  defp discard_prepared_root(state, error, binding),
    do: {:noreply, job(state, :prepare, fn -> cleanup_prepared_root(state, error, binding) end)}

  # Only a preparation which returned no Conversation reaches this cleanup.
  # Normal live Conversation delivery and unbinding remain native-owned.
  defp cleanup_prepared_root(state, error, binding) do
    cleanup = close_sessions(state)
    Enum.each([state.manager, state.session], &stop/1)
    if state.local_runtime, do: stop(state.local_runtime.server)

    binding_cleanup =
      if binding do
        case safe(fn -> Goal.attribution(state.goal, binding) end) do
          {:ok, _} -> safe(fn -> Goal.unbind(state.goal, binding) end)
          {:error, %Error{class: :forbidden}} -> {:ok, :unbound}
          other -> other
        end
      else
        {:ok, :unbound}
      end

    if match?({:ok, %{status: :confirmed}}, cleanup) and
         binding_cleanup == {:ok, :unbound} do
      {:error, error}
    else
      {:error,
       Error.new(:unknown_outcome, "Prepared runtime cleanup was not confirmed",
         details: %{preparation: error, cleanup: cleanup, binding_cleanup: binding_cleanup}
       )}
    end
  end

  defp continue_goal_recovery(state, [], recovered) do
    state = %{state | goal_recovery: %{diagnostic: :none}}

    {:noreply,
     job(state, :recover, fn -> finalize_goal_recovery(state.session_id, recovered) end)}
  end

  defp continue_goal_recovery(state, [group | remaining], recovered) do
    case GoalLifecycle.bind_recovery(state.goal, group) do
      {:ok, bound} ->
        {:noreply,
         job(state, {:goal_recovery, remaining, recovered}, fn ->
           GoalLifecycle.deliver_and_ack(state.goal, group, bound)
         end)}

      {:error, error} ->
        finish_job(:recover, {:error, error}, state)
    end
  end

  defp prepare(host, state, context, run_id, content) do
    locator = RunInventory.root(state.session_id, state.store, run_id, context.mode_provenance)

    with :ok <- RunInventory.retain(locator),
         {:ok, history} <- ProviderMessages.from_host(context.messages),
         {:ok, selection} <- Profiles.selection(context),
         {:ok, plan} <- Discovery.plan(context.agent, selection),
         {:ok, revisions} <-
           Synapsis.Agent.Tools.MCPSources.revisions(context.agent, plan.runtime),
         authority = authority(state.session_id, run_id, plan.runtime, revisions),
         {:ok, session, manager} <- owners(host, state, authority) do
      result =
        with {:ok, local_runtime} <- NativeLocal.open(selection, state.local_runtime) do
          result =
            with {:ok, binding} <- Session.bind(session, authority, incarnation: 1),
                 {:ok, native} <-
                   collaboration_profile(%{collaboration_runtime: manager}, authority, selection),
                 runtime = %{
                   state
                   | session: session,
                     manager: manager,
                     binding: binding,
                     local_runtime: local_runtime,
                     collaboration_descriptors:
                       Enum.flat_map(native, &Map.values(&1.registry.tools))
                 },
                 {:ok, opts, metadata} <-
                   options(runtime, context, run_id, 1, history, authority, false) do
              Enum.each([session, manager], &Process.unlink/1)
              if local_runtime, do: Process.unlink(local_runtime.server)

              {:ok,
               %{
                 options: opts,
                 session: session,
                 manager: manager,
                 binding: binding,
                 local_runtime: local_runtime,
                 collaboration_descriptors: runtime.collaboration_descriptors,
                 browser_resources:
                   Map.take(metadata.browser_resources, [{binding.owner_id, binding.incarnation}]),
                 browser_pruned:
                   Map.drop(state.browser_resources, Map.keys(metadata.browser_resources)),
                 mcp_resource_runtimes:
                   Map.take(metadata.mcp_resource_runtimes, [
                     {binding.owner_id, binding.incarnation}
                   ]),
                 mcp_resource_pruned:
                   Map.drop(state.mcp_resource_runtimes, Map.keys(metadata.mcp_resource_runtimes)),
                 metadata: metadata,
                 content: content
               }}
            end

          if match?({:error, _}, result) and not is_nil(local_runtime) and
               local_runtime != state.local_runtime,
             do: stop(local_runtime.server)

          result
        end

      if match?({:error, _}, result) do
        Session.close(session)
        stop(manager)
        stop(session)
      end

      result
    end
  end

  defp owners(_host, %{session: session, manager: manager}, _authority) when is_pid(session),
    do: {:ok, session, manager}

  defp owners(host, state, authority) do
    with {:ok, session} <- Session.start_link(owner_pid: host, cleanup_timeout: 20_000),
         {:ok, manager} <-
           MultiAgent.start_link(
             parent_run_id: authority.run_id,
             parent_name: "/root",
             parent_authority: authority,
             subscriber: host,
             max_concurrent_threads_per_session: state.limit,
             child_options: fn request, run_id, parent ->
               GenServer.call(
                 host,
                 {:child_options, request, run_id, parent},
                 if("synapsis::browser" in authority.grants, do: 25_000, else: 10_000)
               )
             end,
             admission_receipt: fn receipt ->
               GenServer.call(host, {:receipt, receipt}, 10_000)
             end
           ) do
      {:ok, session, manager}
    end
  end

  defp prepared_child(request, run_id, parent, parent_context, intent, state) do
    identity = parent.child

    with :ok <- child_configuration(request, parent_context),
         {:ok, messages} <- fork_messages(state, request, parent) do
      case reserve_child_session(state, identity, run_id, parent.authority) do
        {:ok, binding, state} ->
          result =
            options(
              %{state | binding: binding},
              parent_context,
              run_id,
              identity.incarnation,
              messages,
              parent.authority,
              true
            )

          case result do
            {:ok, options, metadata} ->
              options =
                options
                |> Keyword.put(:session_binding, binding)
                |> Keyword.put(:thread_id, identity.run_id)
                |> Keyword.put(
                  :host_metadata,
                  Map.take(intent, [:name, :agent_id, :parent_name])
                )

              {:reply, {:ok, options},
               %{
                 state
                 | tool_contexts: Map.put(state.tool_contexts, metadata.key, metadata.entry),
                   browser_resources: metadata.browser_resources,
                   mcp_resource_runtimes: metadata.mcp_resource_runtimes,
                   runs:
                     Map.put(state.runs, run_id, %{
                       identity: identity,
                       store: state.store,
                       context: parent_context
                     })
               }}

            {:error, _} = error ->
              {:reply, error, discard_child_reservation(state, identity, binding)}
          end

        {:error, error, state} ->
          {:reply, {:error, error}, state}
      end
    else
      {:error, %Error{}} = error ->
        {:reply, error, state}

      {:error, _} ->
        {:reply, failure(:execution_failure, "Subagent intent could not be persisted"),
         %{state | error: :storage_failed}}
    end
  end

  defp reserve_child_session(state, identity, run_id, authority) do
    case child_session_owner(state, identity) do
      {:ok, child, state, new?} ->
        ceiling = run_authority(state, authority, run_id)

        case Session.bind(child.session, ceiling, incarnation: identity.incarnation) do
          {:ok, binding} ->
            child = %{child | binding: binding, identity: identity}
            {:ok, binding, put_in(state, [:child_sessions, identity.agent_id], child)}

          {:error, error} ->
            # Refusal to bind an existing owner must leave its active resources intact.
            state =
              if new? do
                stop(child.session)
                %{state | child_sessions: Map.delete(state.child_sessions, identity.agent_id)}
              else
                state
              end

            {:error, error, state}
        end

      {:error, _, _} = error ->
        error
    end
  end

  defp child_session_owner(state, identity) do
    case state.child_sessions[identity.agent_id] do
      nil ->
        start_child_session(state, identity)

      %{cleanup: {:ok, %{status: :confirmed}}} = child ->
        state = forget_closed_child_browser(state, child)
        stop(child.session)
        start_child_session(state, identity)

      %{closing: true} ->
        {:error, Error.new(:resource_conflict, "Child Session cleanup is pending"), state}

      child ->
        case safe(fn -> Session.status(child.session) end) do
          %{phase: :closed, cleanup: {:ok, %{status: :confirmed}}} ->
            state =
              state |> forget_closed_child_browser(child) |> forget_closed_child_resources(child)

            stop(child.session)
            start_child_session(state, identity)

          %{phase: :closed} ->
            {:error, Error.new(:unknown_outcome, "Child Session cleanup is unconfirmed"), state}

          %{phase: _} ->
            {:ok, child, state, false}

          {:error, error} ->
            {:error, error, state}
        end
    end
  end

  defp forget_closed_child_browser(state, %{session: session, binding: binding})
       when is_map(binding) do
    key = {binding.owner_id, binding.incarnation}

    case state.browser_resources[key] do
      %{binding: %{session: ^session, owner_id: owner, incarnation: incarnation}}
      when owner === binding.owner_id and incarnation === binding.incarnation ->
        %{state | browser_resources: Map.delete(state.browser_resources, key)}

      _ ->
        state
    end
  end

  defp forget_closed_child_browser(state, _child), do: state

  defp forget_closed_child_resources(state, %{session: session, binding: binding})
       when is_map(binding) do
    key = {binding.owner_id, binding.incarnation}

    case state.mcp_resource_runtimes[key] do
      %{binding: %{session: ^session, owner_id: owner, incarnation: incarnation}}
      when owner === binding.owner_id and incarnation === binding.incarnation ->
        %{state | mcp_resource_runtimes: Map.delete(state.mcp_resource_runtimes, key)}

      _ ->
        state
    end
  end

  defp forget_closed_child_resources(state, _child), do: state

  defp start_child_session(state, identity) do
    case Session.start_link(owner_pid: self_host(state), cleanup_timeout: 20_000) do
      {:ok, session} ->
        child = %{
          session: session,
          binding: nil,
          identity: identity,
          closing: false,
          cleanup: :not_requested
        }

        {:ok, child, put_in(state, [:child_sessions, identity.agent_id], child), true}

      {:error, error} ->
        {:error, error, state}
    end
  end

  defp discard_child_reservation(state, identity, binding) do
    state =
      state
      |> put_in([:child_sessions, identity.agent_id, :closing], true)
      |> close_prepared_targets({identity.run_id, identity.incarnation})

    job(state, {:child_cleanup, identity.agent_id, binding}, fn ->
      Session.close(binding)
    end)
  end

  defp run_authority(state, authority, run_id) do
    authority
    |> Map.put(:caller, "synapsis:" <> state.session_id)
    |> Map.put(:run_id, run_id)
  end

  defp options(state, context, run_id, incarnation, messages, parent_authority, child?) do
    identity = %{
      caller: "synapsis:" <> state.session_id,
      session_id: state.session_id,
      run_id: run_id,
      incarnation: incarnation,
      catalog_revision: 1
    }

    filesystem_preparation = filesystem_preparation(self_host(state), run_id, incarnation)
    ceiling = run_authority(state, parent_authority, run_id)
    skill_preparation = skill_search_preparation(self_host(state), run_id, incarnation)
    workshop_preparation = skill_workshop_preparation(self_host(state), run_id, incarnation)

    with {:ok, selected} <- Profiles.selection(context),
         {:ok, plan} <-
           Discovery.plan(
             context.agent,
             selected,
             if(child? and Map.get(context.agent, :deferred_tool_names, []) != [], do: ceiling)
           ),
         selection = plan.selected,
         context = %{
           context
           | agent:
               context.agent
               |> Map.put(:tools, selection)
               |> Map.put(:deferred_tool_names, plan.deferred)
         },
         context = filesystem_context(context, selection, filesystem_preparation.fetch),
         # Admission and execution use this same final provider/request pair, including
         # the existing fixture overlay. Never infer the active model from a historical
         # session selection after these request options have been assembled.
         provider_context =
           %{
             provider_config: context.provider_config,
             request_options: %{
               model: context.agent[:model] || context.session.model,
               system_prompt: system_prompt(context, child?),
               max_tokens: context.agent[:max_tokens] || 8192,
               reasoning_effort: context.agent[:reasoning_effort],
               history_projection: context.agent[:history_projection]
             }
           }
           |> Map.merge(state.fixture_context),
         {:ok, native} <- native_bundles(state, ceiling, selection, child?),
         {:ok, local} <-
           NativeLocal.bundles(local_context(state, context, run_id, child?), ceiling, selection),
         {:ok, process_inspection} <-
           ProcessInspection.bundles(
             local_context(state, context, run_id, child?),
             identity,
             ceiling,
             selection
           ),
         {:ok, code_mode} <-
           CodeMode.bundles(%{session_binding: state.binding}, ceiling, selection),
         {:ok, web} <- Fetch.bundles(context, identity, ceiling, selection, state.binding),
         {:ok, web_search} <-
           Search.bundles(context, identity, ceiling, selection, state.binding),
         {:ok, browser, browser_resources} <-
           Browser.bundles(
             context,
             identity,
             ceiling,
             selection,
             state.binding,
             state.browser_resources
           ),
         {:ok, resources, mcp_resource_runtimes} <-
           MCPResources.bundles(
             context,
             identity,
             ceiling,
             selection,
             state.binding,
             state.mcp_resource_runtimes
           ),
         {:ok,
          %{
            bundle: bundle,
            snapshot: snapshot,
            discovery: discovery,
            skill_body_cache: skill_cache
          }} <-
           Profiles.build(
             context
             |> Map.put(:tool_primary?, not child?)
             |> Map.put(:skill_search_preparation, skill_preparation)
             |> Map.put(:skill_workshop_preparation, workshop_preparation)
             |> Map.put(:tool_session_binding, state.binding),
             identity,
             native ++
               local ++
               process_inspection ++
               code_mode ++
               web ++
               web_search ++
               browser ++ resources,
             ceiling
           ) do
      tool_context_resolver = fn invocation, catalog ->
        GenServer.call(self_host(state), {:tool_context, invocation, catalog}, 5_000)
      end

      provider_context = Map.put(provider_context, :tool_context_resolver, tool_context_resolver)

      host_context = %{
        mode_provenance: context.mode_provenance,
        input_context: context[:input_context],
        tool_operator_id: Approval.operator_id(),
        tool_context_resolver: tool_context_resolver,
        filesystem_preparation: filesystem_preparation
      }

      metadata = %{
        key: {run_id, incarnation},
        entry: %{
          snapshot: snapshot,
          discovery: discovery,
          skill_body_cache: skill_cache,
          skill_context: context,
          skill_ceiling: ceiling,
          skill_successors: [],
          prepared_targets: %{},
          prepared_target_bytes: 0,
          prepared_targets_closed?: false
        },
        browser_resources: browser_resources,
        mcp_resource_runtimes: mcp_resource_runtimes
      }

      {:ok,
       [
         run_id: run_id,
         incarnation: incarnation,
         store: Store,
         context: state.store,
         provider: state.provider,
         provider_context: provider_context,
         host_context: host_context,
         hooks: Policy,
         messages: messages,
         registry: bundle.registry,
         tools: bundle.tools,
         authority: bundle.authority,
         schema_admission: :strict,
         tool_result_contract: &select_tool_result_contract/2,
         work: 100,
         run_timeout: :infinity,
         effect_timeout: 600_000,
         commit_timeout: 5_000,
         cleanup_timeout: if("synapsis::browser" in selection, do: 20_000, else: 5_000)
       ], metadata}
    end
  end

  defp select_tool_result_contract(descriptor, identity) do
    case SkillResultContract.select(descriptor, identity) do
      :default -> FilesystemResultContract.select(descriptor, identity)
      selected -> selected
    end
  end

  # Every candidate is frozen before native staging. Resolve only against the
  # actual Conversation catalog, never the most recently prepared host snapshot.
  defp project_skill_catalog(entry, identity, catalog) do
    candidates = [
      %{revision: 1, snapshot: entry.snapshot} | Map.get(entry, :skill_successors, [])
    ]

    candidates
    |> Enum.filter(fn candidate ->
      candidate.revision < catalog.revision or
        (candidate.revision == catalog.revision and
           Map.get(candidate, :publication_id) === Map.get(catalog, :publication_id))
    end)
    |> Enum.sort_by(& &1.revision, :desc)
    |> Enum.reduce_while({:error, :scope_mismatch}, fn candidate, _ ->
      case Profiles.project_catalog(identity, candidate.snapshot, catalog) do
        {:ok, projected} -> {:halt, {:ok, projected}}
        _ -> {:cont, {:error, :scope_mismatch}}
      end
    end)
  end

  defp skill_workshop_preparation(adapter, run_id, incarnation) do
    fn operation, catalog ->
      with true <- operation[:run_id] === run_id and operation[:incarnation] === incarnation,
           {:ok, issued, context, binding, ceiling} <-
             GenServer.call(adapter, {:skill_successor_context, operation, catalog}, 5_000),
           {:ok, live} <- skill_execution(operation),
           {:ok, snapshot} <-
             Synapsis.SkillDiscovery.capture(
               Synapsis.SkillReader.agent_id(issued.skill_snapshot),
               live
             ),
           {:ok, prepared} <-
             Profiles.skill_successor(
               context,
               issued,
               catalog,
               snapshot,
               binding,
               skill_search_preparation(adapter, run_id, incarnation),
               ceiling
             ) do
        update = %{
          run_id: run_id,
          incarnation: incarnation,
          publication_id: Ecto.UUID.generate(),
          expected_revision: catalog.revision,
          catalog: Map.put(prepared.bundle, :revision, catalog.revision + 1)
        }

        case GenServer.call(
               adapter,
               {:skill_successor_register, operation, catalog, update, prepared},
               5_000
             ) do
          :ok ->
            {:ok, update}

          error ->
            SkillBodyCache.release(prepared.skill_body_cache)
            Discovery.release(prepared.discovery)
            error
        end
      else
        false -> {:error, :scope_mismatch}
        error -> error
      end
    end
  end

  defp skill_execution(%{backend_context: %{effect_deadline: getter}})
       when is_function(getter, 0) do
    with {:ok, %{deadline_ms: deadline, remaining_ms: remaining, paused: false}} <- getter.(),
         true <- is_integer(deadline) and remaining > 0 do
      {:ok,
       %{
         deadline: deadline,
         assert_live: fn ->
           case getter.() do
             {:ok, %{remaining_ms: value, paused: false}} when value > 0 -> :ok
             _ -> {:error, :timeout}
           end
         end
       }}
    else
      _ -> {:error, :timeout}
    end
  end

  defp skill_execution(_), do: {:error, :invalid_execution}

  defp skill_search_preparation(adapter, run_id, incarnation) do
    fn operation, catalog ->
      if operation[:run_id] === run_id and operation[:incarnation] === incarnation do
        with {:ok, snapshot} <-
               GenServer.call(adapter, {:tool_context, operation, catalog}, 5_000),
             do: Profiles.prepare_skill_search(operation, catalog, snapshot)
      else
        {:error, :scope_mismatch}
      end
    end
  end

  defp filesystem_context(context, selection, resolver) do
    if Enum.any?(selection, &(&1 in @filesystem_names)) do
      options = [
        node_executable: Application.get_env(:synapsis_agent, :filesystem_node),
        model_budget: filesystem_model_budget(context.agent[:model_context_window])
      ]

      options =
        case Synapsis.Provider.ModelRegistry.get(context.agent[:model] || context.session.model) do
          {:ok, %{supports_images: vision}} when is_boolean(vision) ->
            Keyword.put(options, :model_has_vision, vision)

          _ ->
            options
        end

      Map.put(context, :tool_filesystem, %{
        path_environment: %{
          cwd: context.project_path,
          os_home: System.user_home(),
          platform: filesystem_platform(),
          workspace_root: Path.expand(Synapsis.WorkspaceDocuments.root())
        },
        prepared_target_resolver: resolver,
        execution_options: options
      })
    else
      context
    end
  end

  defp filesystem_platform do
    case :os.type() do
      {:unix, :linux} -> :linux
      {:unix, :darwin} -> :darwin
      {:win32, _} -> :win32
      _ -> nil
    end
  end

  # OpenClaw 488631c agents/tool-result-limits.ts. BEAM numbers are finite;
  # missing or nonnumeric model context leaves the source budget unspecified.
  defp filesystem_model_budget(context) when is_number(context) and context > 0 do
    tokens = floor(context)

    hard_cap =
      cond do
        tokens >= 200_000 -> 64_000
        tokens >= 100_000 -> 32_000
        true -> 16_000
      end

    %{
      maxChars: min(floor(context * 0.3) * 4, hard_cap),
      maxContextChars: max(1_024, floor(max(1, tokens) * 2 * 0.5))
    }
  end

  defp filesystem_model_budget(_), do: nil

  defp filesystem_preparation(adapter, run_id, incarnation) do
    binding = {run_id, incarnation}

    %{
      reserve: fn identity, catalog, digest ->
        filesystem_preparation_call(
          adapter,
          binding,
          identity,
          {:filesystem_target_reserve, identity, catalog, digest}
        )
      end,
      seal: fn identity, catalog, token, candidate, digest ->
        filesystem_preparation_call(
          adapter,
          binding,
          identity,
          {:filesystem_target_seal, identity, catalog, token, candidate, digest}
        )
      end,
      fetch: fn identity, catalog, digest ->
        filesystem_preparation_call(
          adapter,
          binding,
          identity,
          {:filesystem_target_fetch, identity, catalog, digest}
        )
      end,
      abandon: fn identity, catalog, token ->
        filesystem_preparation_call(
          adapter,
          binding,
          identity,
          {:filesystem_target_abandon, identity, catalog, token}
        )
      end
    }
  end

  defp filesystem_preparation_call(adapter, {run_id, incarnation}, identity, message)
       when is_map(identity) do
    if identity[:run_id] === run_id and identity[:incarnation] === incarnation,
      do: GenServer.call(adapter, message, 5_000),
      else: {:error, :scope_mismatch}
  end

  defp filesystem_preparation_call(_, _, _, _), do: {:error, :invalid_prepared_target}

  defp filesystem_target_context(state, identity, catalog) do
    with true <- not state.closing and is_nil(state.error),
         true <- filesystem_target_identity?(identity),
         context_key = {identity.run_id, identity.incarnation},
         %{prepared_targets_closed?: false, prepared_targets: targets} = entry <-
           state.tool_contexts[context_key],
         true <- is_map(targets),
         {:ok, projected} <- Profiles.project_catalog(identity, entry.snapshot, catalog),
         {:ok, descriptor} <- Map.fetch(projected.issued_descriptors, identity.tool_name),
         true <-
           identity.tool_name in @filesystem_names and identity.tool_revision === 1 and
             descriptor[:tool_name] === identity.tool_name and
             descriptor[:tool_revision] === 1 and descriptor[:backend] === Filesystem,
         true <-
           Map.has_key?(projected.selected, identity.tool_name) and
             filesystem_descriptor_context?(descriptor[:backend_context], identity) do
      key =
        {identity.run_id, identity.incarnation, identity.catalog_revision, identity.invocation_id,
         identity.tool_name, identity.tool_revision}

      correlation =
        identity
        |> Map.take(@filesystem_correlation_fields)
        |> Map.put(
          :enclosing_invocation_id,
          identity[:enclosing_invocation_id] || identity.invocation_id
        )

      {:ok, context_key, entry, key, correlation, descriptor}
    else
      {:error, _} = error -> error
      _ -> {:error, :prepared_target_unavailable}
    end
  end

  defp filesystem_target_identity?(identity) when is_map(identity) and not is_struct(identity) do
    required = @filesystem_identity_fields

    Map.keys(identity) -- (required ++ [:enclosing_invocation_id]) == [] and
      Enum.all?(required, &Map.has_key?(identity, &1)) and
      Enum.all?(required -- [:incarnation, :catalog_revision, :tool_revision], fn field ->
        filesystem_identity_string?(identity[field])
      end) and
      Enum.all?([:incarnation, :catalog_revision, :tool_revision], fn field ->
        is_integer(identity[field]) and identity[field] > 0
      end) and
      (is_nil(identity[:enclosing_invocation_id]) or
         filesystem_identity_string?(identity.enclosing_invocation_id))
  end

  defp filesystem_target_identity?(_), do: false

  defp filesystem_identity_string?(value),
    do:
      is_binary(value) and byte_size(value) in 1..4_096 and String.valid?(value) and
        String.trim(value) != "" and not String.contains?(value, "\0")

  defp filesystem_digest?(value), do: is_binary(value) and byte_size(value) == 32

  defp filesystem_descriptor_context?(context, identity) when is_map(context) do
    context[:run_id] === identity.run_id and context[:incarnation] === identity.incarnation and
      is_integer(context[:catalog_revision]) and context.catalog_revision > 0 and
      filesystem_absolute_path?(context[:root]) and is_map(context[:workspace]) and
      context.workspace[:role] in [:global, :agent, :session, :user]
  end

  defp filesystem_descriptor_context?(_, _), do: false

  defp filesystem_target_record(identity, descriptor, key, envelope, candidate, digest) do
    with true <- is_map(candidate) and not is_struct(candidate),
         true <- Enum.sort(Map.keys(candidate)) == Enum.sort(@filesystem_candidate_fields),
         true <- filesystem_public_path?(candidate.original_path, identity.tool_name),
         true <- filesystem_public_path?(candidate.public_path, identity.tool_name),
         true <- filesystem_path_string?(candidate.source_path) and candidate.source_path != "",
         true <-
           is_nil(candidate.requested_absolute) or
             filesystem_absolute_path?(candidate.requested_absolute),
         {:ok, namespace, resource_path} <-
           filesystem_target_shape(candidate, descriptor.backend_context),
         true <- filesystem_source_prefix?(candidate, identity.tool_name) do
      verb =
        case identity.tool_name do
          "synapsis::read" -> "read"
          "synapsis::write" -> "write"
          "synapsis::edit" -> "edit"
          "synapsis::ls" -> "list"
        end

      {:ok,
       Map.merge(candidate, %{
         version: 1,
         key: key,
         correlation: envelope.correlation,
         raw_arguments_digest: envelope.raw_arguments_digest,
         prepared_arguments_digest: digest,
         action: namespace <> "." <> verb,
         resource: namespace <> ":" <> resource_path
       })}
    else
      _ -> {:error, :invalid_prepared_target}
    end
  end

  defp filesystem_public_path?(:omitted, "synapsis::ls"), do: true
  defp filesystem_public_path?(path, _name), do: filesystem_path_string?(path)

  defp filesystem_path_string?(path),
    do:
      is_binary(path) and byte_size(path) <= @prepared_target_record_limit and
        String.valid?(path) and not String.contains?(path, "\0")

  defp filesystem_absolute_path?(path),
    do:
      filesystem_path_string?(path) and path != "" and Path.type(path) == :absolute and
        Path.expand(path, "/") == path

  defp filesystem_relative_path?("."), do: true

  defp filesystem_relative_path?(path),
    do:
      filesystem_path_string?(path) and path != "" and Path.type(path) == :relative and
        Path.join(Path.split(path)) == path and
        not Enum.any?(Path.split(path), &(&1 in [".", ".."]))

  defp filesystem_target_shape(%{target: {:local, absolute, relative}}, _context) do
    # Root aliases can map to a different physical prefix. The domain owner
    # revalidates containment; this metadata owner checks only tuple structure.
    if filesystem_absolute_path?(absolute) and filesystem_relative_path?(relative),
      do: {:ok, "filesystem", absolute},
      else: {:error, :invalid_prepared_target}
  end

  defp filesystem_target_shape(
         %{target: {:workspace, logical}, source_path: source, requested_absolute: nil},
         %{workspace: workspace}
       ) do
    if is_map(workspace) and filesystem_absolute_path?(logical) and
         source === "@synapsis" <> logical,
       do: {:ok, "workspace", logical},
       else: {:error, :invalid_prepared_target}
  end

  defp filesystem_target_shape(_, _), do: {:error, :invalid_prepared_target}

  defp filesystem_source_prefix?(%{source_prefix: ""}, _name), do: true

  defp filesystem_source_prefix?(
         %{
           target: {:local, selected, _},
           requested_absolute: requested,
           source_prefix: prefix
         },
         "synapsis::read"
       )
       when is_binary(requested) and is_binary(prefix) do
    requested_name = Path.basename(requested)
    selected_name = Path.basename(selected)

    requested_name != selected_name and
      prefix === "[Resolved filename: #{requested_name} -> #{selected_name}.]\n"
  end

  defp filesystem_source_prefix?(_, _), do: false

  defp put_prepared_target(state, context_key, entry, key, envelope) do
    previous = entry.prepared_targets[key]
    previous_bytes = if previous, do: prepared_target_size(key, previous), else: 0
    bytes = prepared_target_size(key, envelope)
    total = entry.prepared_target_bytes - previous_bytes + bytes

    if bytes <= @prepared_target_record_limit and total <= @prepared_target_bytes_limit do
      entry = %{
        entry
        | prepared_targets: Map.put(entry.prepared_targets, key, envelope),
          prepared_target_bytes: total
      }

      {:ok, put_in(state, [:tool_contexts, context_key], entry)}
    else
      {:error, :prepared_target_limit}
    end
  end

  defp prepared_target_size(key, envelope),
    do: byte_size(:erlang.term_to_binary({key, envelope}, [:deterministic]))

  defp demonitor_prepared_target(%{monitor: monitor}) when is_reference(monitor),
    do: Process.demonitor(monitor, [:flush])

  defp demonitor_prepared_target(_), do: :ok

  defp settle_prepared_target_producer(state, monitor, producer) do
    Enum.reduce(state.tool_contexts, state, fn {context_key, entry}, state ->
      Enum.reduce(Map.get(entry, :prepared_targets, %{}), state, fn
        {key, %{monitor: ^monitor, producer_pid: ^producer} = envelope}, state ->
          settled = %{
            envelope
            | monitor: nil,
              state: if(envelope.state == :reserved, do: :abandoned, else: envelope.state)
          }

          {:ok, state} =
            put_prepared_target(
              state,
              context_key,
              state.tool_contexts[context_key],
              key,
              settled
            )

          state

        _, state ->
          state
      end)
    end)
  end

  defp close_prepared_targets(state, scope) do
    keys =
      for {{run_id, _} = key, _entry} <- state.tool_contexts,
          scope == :all or scope === key or scope === run_id,
          into: MapSet.new(),
          do: key

    contexts =
      Enum.reduce(state.tool_contexts, state.tool_contexts, fn {key, entry}, acc ->
        if MapSet.member?(keys, key) do
          Enum.each(Map.get(entry, :prepared_targets, %{}), fn {_, envelope} ->
            demonitor_prepared_target(envelope)
          end)

          if not skill_resources?(entry) do
            Map.delete(acc, key)
          else
            Map.put(
              acc,
              key,
              Map.merge(entry, %{
                prepared_targets: %{},
                prepared_target_bytes: 0,
                prepared_targets_closed?: true
              })
            )
          end
        else
          acc
        end
      end)

    %{state | tool_contexts: contexts}
  end

  defp local_context(state, context, run_id, _child?) do
    %{
      workspace: context.project_path,
      caller: %{run_id: run_id},
      command: if(state.local_runtime, do: state.local_runtime.command),
      session_registry: state.binding.resource_registry,
      session_binding: state.binding
    }
  end

  defp native_bundles(state, authority, selection, true) do
    selected = Enum.filter(selection, &(&1 in @collaboration))

    # Child options run inside the manager's synchronous admission callback.
    # Bind the cached originals just as Codex.profile/4 does, without calling that manager.
    descriptors =
      state.collaboration_descriptors
      |> Enum.filter(&(&1.tool_name in selected))
      |> Enum.map(fn descriptor ->
        Map.update!(descriptor, :backend_context, &Map.put(&1, :session_binding, state.binding))
      end)

    cond do
      selected == [] ->
        {:ok, []}

      not Enum.all?(selected, &(&1 in authority.grants)) ->
        failure(:forbidden, "Collaboration tools exceed the parent authority ceiling")

      Enum.sort(Enum.map(descriptors, & &1.tool_name)) != Enum.sort(selected) ->
        failure(:unsupported_capability, "Selected collaboration descriptors are unavailable")

      true ->
        native_authority = %{
          authority
          | grants: selected,
            tool_revisions: Map.take(authority.tool_revisions, selected)
        }

        case ToolCatalog.admit_batch(descriptors, authority: native_authority, mode: :strict) do
          {:ok, bundle} -> {:ok, [bundle]}
          error -> error
        end
    end
  end

  defp native_bundles(state, authority, selection, false) do
    collaboration_profile(
      %{collaboration_runtime: state.manager, session_binding: state.binding},
      authority,
      selection
    )
  end

  defp collaboration_profile(context, authority, selection) do
    selected = Enum.filter(selection, &(&1 in @collaboration))

    if selected != [] do
      if Enum.all?(selected, &(&1 in authority.grants)) do
        native_authority = %{
          authority
          | grants: selected,
            tool_revisions: Map.take(authority.tool_revisions, selected)
        }

        # TODO(upstream): gsmlg-opt/backplane#99 — confirmed provider interruption
        # currently prevents the parent Session's native transfer/completion check.
        case Codex.profile(:collaboration_v2, context, native_authority, tools: selected) do
          {:ok, bundle} -> {:ok, [bundle]}
          error -> error
        end
      else
        failure(:forbidden, "Collaboration tools exceed the parent authority ceiling")
      end
    else
      {:ok, []}
    end
  end

  defp authority(session_id, run_id, selection, revisions) do
    %{
      caller: "synapsis:" <> session_id,
      run_id: run_id,
      grants: selection,
      tool_revision: 1,
      tool_revisions: revisions
    }
  end

  defp system_prompt(context, false), do: context.system_prompt

  defp system_prompt(context, true) do
    case context[:child_system_prompt] do
      prompt when is_binary(prompt) and prompt != "" -> prompt
      _ -> Synapsis.Agent.ContextBuilder.load_base_prompt(:coding, context.agent)
    end
  end

  defp child_configuration(request, context) do
    opts = request.options
    model = context.agent[:model] || context.session.model

    cond do
      opts["model"] not in [nil, "", model] ->
        failure(:unsupported_capability, "Child model override is not configured")

      opts["agent_type"] not in [nil, "", "default"] ->
        failure(:unsupported_capability, "Child agent type is not configured")

      opts["reasoning_effort"] not in [nil, "", context.agent[:reasoning_effort]] ->
        failure(:unsupported_capability, "Child reasoning override is not configured")

      true ->
        :ok
    end
  end

  defp fork_messages(state, request, parent) do
    mode = request.options["fork_turns"] || "all"

    if mode == "none" do
      {:ok, []}
    else
      with {:ok, record} <- Store.load(state.store, parent.run_id),
           messages when is_list(messages) <-
             get_in(record, [:run, :context, :conversation, :messages]) do
        messages = complete_prefix(messages)

        case mode do
          "all" ->
            {:ok, messages}

          value when is_binary(value) ->
            case Integer.parse(value) do
              {count, ""} when count > 0 ->
                indices = for {%{role: :user}, i} <- Enum.with_index(messages), do: i
                index = List.first(Enum.take(indices, -count)) || 0
                {:ok, Enum.drop(messages, index)}

              _ ->
                failure(:validation, "fork_turns must be none, all or a positive integer string")
            end

          _ ->
            failure(:validation, "fork_turns must be a string")
        end
      else
        _ -> failure(:execution_failure, "Committed parent history is unavailable")
      end
    end
  end

  defp complete_prefix(messages) do
    {safe, pending} =
      Enum.reduce(Enum.with_index(messages), {length(messages), MapSet.new()}, fn
        {%{role: :assistant, content: blocks}, i}, {safe, pending} when is_list(blocks) ->
          calls = for %{type: :tool_call, id: id} <- blocks, do: id

          {if(calls != [] and MapSet.size(pending) == 0, do: i, else: safe),
           Enum.reduce(calls, pending, &MapSet.put(&2, &1))}

        {%{role: :tool, tool_call_id: id}, i}, {safe, pending} ->
          pending = MapSet.delete(pending, id)
          {if(MapSet.size(pending) == 0, do: i + 1, else: safe), pending}

        _, acc ->
          acc
      end)

    if MapSet.size(pending) == 0, do: messages, else: Enum.take(messages, safe)
  end

  defp remember_permission(state, destination, run_id, event) do
    request = event.request
    identity = get_in(state.runs, [run_id, :identity]) || %{name: "/root"}

    item = %{destination: destination, request: request, run_id: run_id}

    event =
      event
      |> Map.put(:request, display_request(request))
      |> Map.put(:child, identity)
      |> Map.put(:run_id, run_id)

    notify(state, {:runtime_event, state.epoch, state.run_id, event})
    %{state | pending: Map.put(state.pending, event.interaction_id, item)}
  end

  defp display_request(request) do
    operation = request_field(request, :operation) || request

    request
    |> Map.put(:tool_name, request_field(operation, :tool_name))
    |> Map.put(:arguments, request_field(operation, :arguments))
  end

  defp request_field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp forget_permission(state, id) do
    if Map.has_key?(state.pending, id) do
      notify(
        state,
        {:runtime_event, state.epoch, state.run_id,
         %{type: :interaction_resolved, interaction_id: id}}
      )
    end

    %{state | pending: Map.delete(state.pending, id)}
  end

  defp forget_run_permissions(state, run_id) do
    {closed, pending} =
      Enum.split_with(state.pending, fn {_, item} -> item.run_id == run_id end)

    Enum.each(closed, fn {id, _} ->
      notify(
        state,
        {:runtime_event, state.epoch, state.run_id,
         %{type: :interaction_resolved, interaction_id: id}}
      )
    end)

    %{state | pending: Map.new(pending)}
  end

  defp close(%{initializing: true} = state),
    do: close_prepared_targets(%{state | closing: true}, :all)

  defp close(%{closing: true} = state), do: close_prepared_targets(state, :all)
  defp close(%{error: :closed} = state), do: close_prepared_targets(state, :all)

  defp close(state) do
    state = close_prepared_targets(state, :all)

    preparing? =
      Enum.any?(state.jobs, fn {_, {_, _, tag}} -> tag in [:prepare_inputs, :prepare] end)

    cond do
      # The preparation result owns cleanup until it either hands over a live
      # Conversation or confirms that no runtime remains. Do not race a second
      # close job against it or publish a terminal result ahead of that cleanup.
      preparing? ->
        %{state | closing: true}

      is_pid(state.session) ->
        job(%{state | closing: true}, :close, fn ->
          # The root can already be retired by an in-flight terminal status job.
          # A vanished root must not prevent closing its session-owned children.
          if is_pid(state.root), do: safe(fn -> Conversation.cancel(state.root) end)
          cleanup = close_sessions(state)
          history = closed_history(state)
          stop(state.root, owner_stop_timeout(state))
          %{cleanup: cleanup, history: history}
        end)

      true ->
        if state.busy, do: %{state | closing: true}, else: cancelled_without_runtime(state)
    end
  end

  defp close_sessions(state) do
    # Root closure reconciles adopted children through the native manager first.
    cleanup = safe(fn -> Session.close(state.session) end)
    children = close_child_sessions(state)

    if Enum.all?(children, &match?({:ok, %{status: :confirmed}}, &1)),
      do: cleanup,
      else: failure(:unknown_outcome, "Child Session cleanup is unconfirmed")
  end

  defp close_child_sessions(state) do
    Enum.map(state.child_sessions, fn {_id, child} ->
      # The adapter also owns reservations rejected before native adoption.
      result = safe(fn -> Session.close(child.session) end)
      stop(child.session, owner_stop_timeout(state))
      result
    end)
  end

  defp closed_history(state) do
    case safe(fn -> Conversation.status(state.root) end) do
      %{messages: messages} ->
        {:ok, messages}

      _ ->
        with {:ok, record} <- Store.load(state.store, state.run_id),
             messages when is_list(messages) <-
               get_in(record, [:run, :context, :conversation, :messages]) do
          {:ok, messages}
        else
          {:error, _} = error -> error
          _ -> failure(:execution_failure, "Canonical root history is unavailable")
        end
    end
  end

  defp cancelled_without_runtime(state) do
    state = close_prepared_targets(state, :all)

    notify(
      state,
      {:runtime_event, state.epoch, state.run_id,
       %{type: :run_cancelled, cleanup: {:ok, %{status: :confirmed}}}}
    )

    %{state | closing: false, busy: false, pending: %{}, error: :closed}
  end

  defp persist_roster(state) do
    roster = Map.put(state.roster, :namespace, state.store.namespace)

    case Journal.put_projection(state.session_id, roster) do
      :ok ->
        notify(state, {:runtime_roster, state.epoch, roster})
        %{state | roster: roster}

      _ ->
        %{state | error: :storage_failed}
    end
  end

  defp project_root(state, status) do
    root = %{run_id: state.run_id, namespace: state.store.namespace, status: status}
    roster = Map.put(state.roster, :root, root)

    roster =
      if status == :unknown_outcome, do: Map.put(roster, :recovery_required, true), else: roster

    persist_roster(%{state | roster: roster})
  end

  defp unknown(roster) do
    roster
    |> Map.put(:recovery_required, true)
    |> Map.update(:agents, [], fn agents ->
      Enum.map(agents, fn row ->
        if row.status in @settled,
          do: row,
          else: Map.merge(row, %{status: :unknown_outcome, cleanup: :uncertain})
      end)
    end)
    |> Map.update(:root, nil, fn
      nil -> nil
      row -> if row.status in @settled, do: row, else: Map.put(row, :status, :unknown_outcome)
    end)
  end

  defp upsert(items, item, key),
    do: Enum.reject(items, &(Map.fetch!(&1, key) == Map.fetch!(item, key))) ++ [item]

  defp skill_resources?(entry),
    do:
      not is_nil(entry.discovery) or not is_nil(Map.get(entry, :skill_body_cache)) or
        Map.get(entry, :skill_successors, []) != []

  defp cleanup_discovery(state, run_id) do
    pending? =
      Enum.any?(state.jobs, fn {_, {_, _, tag}} -> tag == {:discovery_cleanup, run_id} end)

    if pending? or
         not Enum.any?(state.tool_contexts, fn {{id, _}, entry} ->
           id == run_id and
             skill_resources?(entry)
         end) do
      state
    else
      job(state, {:discovery_cleanup, run_id}, fn ->
        release_discovery(state.tool_contexts, run_id)
      end)
    end
  end

  defp release_discovery(contexts, run_id) do
    for {{id, _} = key, entry} <- contexts,
        id == run_id and
          skill_resources?(entry),
        into: %{} do
      resources = [entry | Map.get(entry, :skill_successors, [])]

      discovery =
        Enum.map(resources, fn resource ->
          safe(fn -> Discovery.release(resource.discovery) end)
        end)

      bodies =
        Enum.map(resources, fn resource ->
          safe(fn -> SkillBodyCache.release(Map.get(resource, :skill_body_cache)) end)
        end)

      result =
        if Enum.all?(discovery, &(&1 == :ok)) and Enum.all?(bodies, &(&1 == :ok)),
          do: :ok,
          else: {:error, %{discovery: discovery, skill_bodies: bodies}}

      {key, result}
    end
  end

  defp record_discovery_cleanup(state, results) do
    confirmed = for {key, :ok} <- results, do: key
    state = Enum.reduce(confirmed, state, &close_prepared_targets(&2, &1))

    %{
      state
      | tool_contexts: Map.drop(state.tool_contexts, confirmed),
        discovery_cleanup: Map.merge(state.discovery_cleanup, results)
    }
  end

  defp merge_browser_resources(live, runtime) do
    # Root preparation runs outside this server. Remove only unchanged records
    # it observed as settled; preserve resources installed by newer child options.
    live =
      Enum.reduce(runtime.browser_pruned, live, fn {key, previous}, cache ->
        if cache[key] === previous, do: Map.delete(cache, key), else: cache
      end)

    Map.merge(live, runtime.browser_resources)
  end

  defp merge_mcp_resource_runtimes(live, runtime) do
    # Root preparation can overlap child options. Preserve newer child records.
    live =
      Enum.reduce(runtime.mcp_resource_pruned, live, fn {key, previous}, cache ->
        if cache[key] === previous, do: Map.delete(cache, key), else: cache
      end)

    Map.merge(live, runtime.mcp_resource_runtimes)
  end

  defp owner_stop_timeout(state),
    do: if(map_size(state.browser_resources) > 0, do: 25_000, else: 10_000)

  defp stop(pid, timeout \\ 10_000)

  defp stop(pid, timeout) when is_pid(pid) do
    Process.unlink(pid)
    if Process.alive?(pid), do: GenServer.stop(pid, :shutdown, timeout)
  catch
    :exit, _ -> Process.exit(pid, :kill)
  end

  defp stop(_, _), do: :ok
  defp notify(state, event), do: send(state.owner, event)
  defp failure(class, message), do: {:error, Error.new(class, message)}
end
