defmodule Synapsis.Agent.Runtime.SessionAdapter do
  @moduledoc "Session-owned root Conversation and nested Backplane collaboration runtime."
  use GenServer

  alias Backplane.AgentRuntime.{Codex, Conversation, Error, ToolCatalog}
  alias Backplane.AgentRuntime.Codex.{MultiAgent, Session}

  alias Synapsis.Agent.Runtime.{
    ProviderAdapter,
    ProviderMessages,
    SessionTools,
    Store,
    ToolRegistry
  }

  alias Synapsis.Runtime.Store, as: Journal
  alias Synapsis.Tool.{Gateway, Registry}
  alias Synapsis.Tool.Capability.PolicySnapshot

  @collaboration ~w(spawn_agent send_message followup_task interrupt_agent list_agents wait_agent)
  @legacy ~w(task teammate team_delete team_create send_message)
  @terminal [:run_completed, :run_failed, :run_cancelled]
  @settled [:completed, :errored, :interrupted, :closed, :shutdown]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def prompt(pid, context, content), do: GenServer.cast(pid, {:prompt, context, content})
  def input(pid, content), do: GenServer.cast(pid, {:input, content})
  def cancel(pid), do: GenServer.cast(pid, :cancel)
  def resolve(pid, id, decision), do: GenServer.cast(pid, {:resolve, id, decision})
  def snapshot(pid), do: GenServer.call(pid, :snapshot)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(opts, :owner)
    id = Keyword.fetch!(opts, :session_id)
    {:ok, store} = Store.new(1)

    saved =
      case Journal.get_projection(id) do
        {:ok, value} -> value
        _ -> %{agents: [], admissions: []}
      end

    {:ok, intents} = Journal.list_facts(id, :admission_intent)
    {:ok, receipts} = Journal.list_facts(id, :admission_receipt)

    unresolved =
      Enum.any?(intents, fn intent ->
        not Enum.any?(receipts, &(&1.attempt_id == intent.attempt_id))
      end) or
        Enum.any?(receipts, fn receipt ->
          receipt.process_started and
            not Enum.any?(saved[:agents] || [], &(&1.agent_id == receipt.agent_id))
        end)

    uncertain =
      unresolved or Enum.any?(saved[:agents] || [], &(&1.status not in @settled)) or
        (is_map(saved[:root]) and saved.root.status not in @settled)

    roster = if uncertain, do: unknown(saved), else: saved

    roster =
      roster
      |> Map.put(:recovery_required, uncertain)
      |> Map.update(:agents, [], fn agents ->
        Enum.map(agents, &Map.merge(&1, %{historical: true, resident: false}))
      end)

    if uncertain, do: Journal.put_projection(id, roster)
    send(owner, {:runtime_roster, Keyword.fetch!(opts, :epoch), roster})

    {:ok,
     %{
       owner: owner,
       owner_ref: Process.monitor(owner),
       session_id: id,
       adapter: self(),
       epoch: Keyword.fetch!(opts, :epoch),
       provider: Keyword.get(opts, :provider, ProviderAdapter),
       fixture_context: Keyword.get(opts, :provider_context, %{}),
       limit: Keyword.get(opts, :max_concurrent_threads_per_session, 4),
       session: nil,
       manager: nil,
       contracts: [],
       store: store,
       root: nil,
       context: nil,
       run_id: nil,
       runs: %{},
       jobs: %{},
       pending: %{},
       roster: roster,
       busy: false,
       closing: false,
       terminal_failure: nil,
       error: if(uncertain, do: :recovery_required)
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state),
    do:
      {:reply,
       Map.put(
         state.roster,
         :pending,
         Enum.map(state.pending, fn {id, x} -> Map.put(x.request, :interaction_id, id) end)
       ), state}

  def handle_call({:child_options, request, run_id, parent}, _from, state) do
    if state.closing or state.error do
      {:reply, failure(:resource_conflict, "Subagent admission is closed"), state}
    else
      identity = parent.child

      previous =
        Enum.find_value(state.runs, fn {_id, run} ->
          if run.identity[:agent_id] == identity.agent_id, do: run.context
        end)

      parent_context = previous || get_in(state.runs, [parent.run_id, :context]) || state.context

      intent =
        Map.merge(identity, %{
          parent_name: parent.name,
          parent_run_id: parent.run_id,
          namespace: state.store.namespace
        })

      with :ok <-
             Journal.put_fact(state.session_id, :admission_intent, identity.attempt_id, intent),
           :ok <- child_configuration(request, parent_context),
           {:ok, messages} <- fork_messages(state, request, parent),
           {:ok, options} <-
             options(
               state,
               parent_context,
               run_id,
               identity.incarnation,
               messages,
               parent.authority,
               true
             ) do
        {:reply,
         {:ok,
          Keyword.put(options, :host_metadata, Map.take(intent, [:name, :agent_id, :parent_name]))},
         %{
           state
           | runs:
               Map.put(state.runs, run_id, %{
                 identity: identity,
                 store: state.store,
                 context: parent_context
               })
         }}
      else
        {:error, %Error{}} = error ->
          {:reply, error, state}

        {:error, _} ->
          {:reply, failure(:execution_failure, "Subagent intent could not be persisted"),
           %{state | error: :storage_failed}}
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
        {:reply, :ok, state}

      _ ->
        {:reply, failure(:execution_failure, "Subagent admission receipt could not be persisted"),
         %{state | error: :storage_failed}}
    end
  end

  @impl true
  def handle_cast({:prompt, context, content}, state) do
    if state.busy or state.closing or state.error do
      notify(state, {:runtime_roster, state.epoch, state.roster})
      notify(state, {:runtime_admission_failed, state.epoch, state.error || :runtime_busy})
      {:noreply, state}
    else
      run_id = Ecto.UUID.generate()
      context = Map.put(context, :policy_snapshot, policy(context, state.session_id, run_id))
      state = %{state | busy: true, context: context, run_id: run_id}

      {:noreply,
       job(state, :prepare, fn -> prepare(self_host(state), state, context, run_id, content) end)}
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
    case Map.pop(state.pending, id) do
      {nil, _} ->
        {:noreply, state}

      {item, pending} ->
        value = approval(item.request, item.host, decision)

        {:noreply,
         job(%{state | pending: pending}, {:resolve, id}, fn ->
           Conversation.resolve(item.pid, id, value)
         end)}
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
        # Loading committed history never calls the collaboration manager.
        {:noreply,
         job(state, {:terminal, event}, fn ->
           status = Conversation.status(state.root)
           stop(state.root)

           if event.type == :run_completed,
             do: status,
             else: Map.put(status, :cleanup, Session.close(state.session))
         end)}

      event.type == :interaction_requested ->
        {:noreply, remember_permission(state, state.root, event)}

      true ->
        notify(state, {:runtime_event, state.epoch, run_id, event})
        {:noreply, state}
    end
  end

  def handle_info({:runtime_permission_owner, pid, request}, state) do
    if request.run_id == state.run_id do
      {:noreply, state}
    else
      {:noreply,
       job(state, {:permission, pid, request}, fn ->
         await_permission(pid, request.approval_id, 500)
       end)}
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
      if event[:agent] && event.agent.status in @settled,
        do: forget_run_permissions(state, event.agent.run_id),
        else: state

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when ref == state.owner_ref,
    do: {:stop, :normal, %{state | error: {:owner_down, reason}}}

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
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
    if pid in [state.session, state.manager, state.root] and reason not in [:normal, :shutdown] do
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
    Enum.each(state.jobs, fn {_ref, {pid, _, _}} -> Process.exit(pid, :kill) end)
    # Session and manager termination fence their owned effects and children;
    # no journal record is ever used to replay an interrupted effect.
    Enum.each([state.root, state.session, state.manager], &stop/1)

    if state.busy or Enum.any?(state.roster[:agents] || [], &(&1.status not in @settled)),
      do: Journal.put_projection(state.session_id, unknown(state.roster))

    :ok
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

  defp finish_job(:prepare, {:ok, runtime}, state) do
    Enum.each([runtime.session, runtime.manager, runtime.root], &Process.link/1)
    state = Map.merge(state, Map.take(runtime, [:session, :manager, :root, :contracts]))

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
        {:noreply,
         job(state, :admission_failure_close, fn ->
           result = Session.close(state.session)
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

  defp finish_job(:prepare, {:error, error}, state) do
    if state.closing do
      {:noreply, cancelled_without_runtime(state)}
    else
      notify(state, {:runtime_admission_failed, state.epoch, error})
      {:noreply, %{state | busy: false, error: :admission_failed}}
    end
  end

  defp finish_job(:admission_failure_close, result, state) do
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
        event.type == :run_completed -> :completed
        match?({:ok, %{status: :confirmed}}, status[:cleanup]) -> :errored
        true -> :unknown_outcome
      end

    state = project_root(state, root_status)
    notify(state, {:runtime_history, state.epoch, state.run_id, messages})
    event = event |> Map.put(:messages, messages) |> Map.put(:cleanup, status[:cleanup])
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
             pending:
               Map.reject(state.pending, fn {_, item} -> item.request.run_id == state.run_id end)
         }}
    end
  end

  defp finish_job({:permission, pid, _request}, {:ok, event}, state),
    do: {:noreply, remember_permission(state, pid, event)}

  defp finish_job({:permission, _, _}, _, state), do: {:noreply, state}

  defp finish_job({:resolve, id}, :ok, state) do
    notify(
      state,
      {:runtime_event, state.epoch, state.run_id,
       %{type: :interaction_resolved, interaction_id: id}}
    )

    {:noreply, state}
  end

  defp finish_job(:close, %{cleanup: result, history: history}, state) do
    failed = state.terminal_failure
    owner_lost = state.error == :runtime_owner_lost
    state = %{state | closing: false, busy: false, pending: %{}, root: nil, error: :closed}

    state =
      if match?({:ok, %{status: :confirmed}}, result) and not owner_lost,
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

  defp prepare(host, state, context, run_id, content) do
    with {:ok, history} <- ProviderMessages.from_host(context.messages),
         {:ok, host_bundle} <- host_bundle(state, context, run_id, false),
         authority = combined_authority(host_bundle.authority),
         {:ok, session, manager} <- owners(host, state, authority) do
      result =
        with {:ok, binding} <- Session.bind(session, authority, incarnation: 1),
             {:ok, collab} <-
               Codex.profile(
                 :collaboration_v2,
                 %{collaboration_runtime: manager, session_binding: binding},
                 %{authority | grants: @collaboration}
               ),
             runtime = %{
               state
               | session: session,
                 manager: manager,
                 contracts: Map.values(collab.registry.tools)
             },
             {:ok, opts} <- options(runtime, context, run_id, 1, history, authority, false),
             {:ok, root} <-
               Conversation.start_link(
                 Keyword.merge(opts, subscriber: host, session_binding: binding)
               ) do
          Enum.each([root, session, manager], &Process.unlink/1)

          {:ok,
           %{
             root: root,
             session: session,
             manager: manager,
             contracts: runtime.contracts,
             content: content
           }}
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
    with {:ok, session} <- Session.start_link(owner_pid: host),
         {:ok, manager} <-
           MultiAgent.start_link(
             parent_run_id: authority.run_id,
             parent_name: "/root",
             parent_authority: authority,
             subscriber: host,
             max_concurrent_threads_per_session: state.limit,
             child_options: fn request, run_id, parent ->
               GenServer.call(host, {:child_options, request, run_id, parent}, 10_000)
             end,
             admission_receipt: fn receipt ->
               GenServer.call(host, {:receipt, receipt}, 10_000)
             end
           ) do
      {:ok, session, manager}
    end
  end

  defp options(state, context, run_id, incarnation, messages, parent_authority, child?) do
    with {:ok, host} <- host_bundle(state, context, run_id, child?),
         authority = combined_authority(host.authority),
         grants = Enum.filter(authority.grants, &(&1 in parent_authority.grants)),
         authority = %{authority | grants: grants},
         descriptors =
           Map.values(host.registry.tools) ++
             collaboration_descriptors(
               state.contracts,
               host.host_context,
               self_host(state),
               child?
             ),
         descriptors = Enum.filter(descriptors, &(&1.tool_name in grants)),
         {:ok, bundle} <-
           ToolCatalog.admit_batch(
             descriptors,
             authority: authority,
             mode: :strict
           ) do
      tools = bundle.tools

      provider_context =
        Map.merge(
          %{
            provider_config: context.provider_config,
            tools: tools,
            request_options: %{
              model: context.agent[:model] || context.session.model,
              system_prompt: context.system_prompt,
              max_tokens: context.agent[:max_tokens] || 8192,
              reasoning_effort: context.agent[:reasoning_effort]
            }
          },
          state.fixture_context
        )

      {:ok,
       [
         run_id: run_id,
         incarnation: incarnation,
         store: Store,
         context: state.store,
         provider: state.provider,
         provider_context: provider_context,
         messages: messages,
         registry: bundle.registry,
         tools: tools,
         authority: bundle.authority,
         schema_admission: :strict,
         work: 100,
         run_timeout: :infinity,
         effect_timeout: 600_000,
         commit_timeout: 5_000,
         cleanup_timeout: 5_000
       ]}
    end
  end

  defp host_bundle(state, context, run_id, child?) do
    names = context.agent[:tools]
    tools = context.agent[:resolved_tools] || Registry.list_for_query_loop(names: names)

    requested =
      if(is_list(names), do: names, else: Enum.map(tools, & &1.name))
      |> Enum.reject(&(&1 in (@legacy ++ ["tool_search"])))

    tools = Enum.reject(tools, &(&1.name in (@legacy ++ ["tool_search"])))
    missing = requested -- Enum.map(tools, & &1.name)

    host = %{
      run_id: run_id,
      session_id: state.session_id,
      project_path: context.project_path,
      parent_agent: child?,
      session_epoch: state.epoch,
      policy_snapshot: policy(context, state.session_id, run_id),
      skill_catalog: context.agent[:skill_catalog],
      skill_loader: context.agent[:skill_loader]
    }

    with true <-
           missing == [] ||
             failure(
               :unsupported_capability,
               "Selected tools unavailable or deferred: #{Enum.join(missing, ", ")}"
             ),
         {:ok, admitted} <-
           ToolRegistry.admit(tools, host, revision: 1, caller: "synapsis:" <> state.session_id) do
      entries =
        Map.new(admitted.registry.tools, fn {name, descriptor} ->
          descriptor =
            descriptor |> Map.put(:description, Enum.find(tools, &(&1.name == name)).description)

          descriptor = %{
            descriptor
            | backend: SessionTools,
              backend_context:
                Map.put(descriptor.backend_context, :interaction_observer, self_host(state))
          }

          {name, descriptor}
        end)

      discovery? = is_nil(names) or "tool_search" in names

      entries =
        if discovery? do
          discovery = %{
            tool_name: "tool_search",
            tool_revision: 1,
            backend: SessionTools,
            backend_context: %{
              host_context: host,
              bounded_discovery: Enum.map(tools, &Map.take(&1, [:name, :description]))
            },
            schema: Synapsis.Tool.ToolSearch.parameters(),
            description:
              "Search this run's admitted tools only. Does not discover or activate deferred or plugin tools.",
            safety: %{read_only: true, retry_safe: true, parallel_safe: true}
          }

          Map.put(entries, "tool_search", discovery)
        else
          entries
        end

      authority =
        Map.update!(
          admitted.authority,
          :grants,
          &if(discovery?, do: &1 ++ ["tool_search"], else: &1)
        )

      {:ok,
       admitted
       |> Map.put(:registry, %{admitted.registry | tools: entries})
       |> Map.put(:authority, authority)
       |> Map.put(:host_context, host)}
    end
  end

  defp policy(context, session_id, run_id) do
    snapshot =
      context[:policy_snapshot] ||
        PolicySnapshot.from_session_config(Synapsis.Tool.Permission.session_config(session_id),
          attended?: true
        )

    %{snapshot | session_id: session_id, run_id: run_id}
  end

  defp collaboration_descriptors(contracts, host, observer, child?) do
    Enum.map(contracts, fn contract ->
      bound =
        Map.merge(contract.backend_context, %{host_context: host, interaction_observer: observer})

      bound = if child?, do: Map.delete(bound, :session_binding), else: bound
      %{contract | backend: SessionTools, backend_context: bound}
    end)
  end

  defp combined_authority(authority),
    do: Map.update!(authority, :grants, &Enum.uniq(&1 ++ @collaboration))

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

  defp await_permission(_pid, _approval, 0),
    do: failure(:timeout, "Permission request did not commit")

  defp await_permission(pid, approval, remaining) do
    case Conversation.status(pid) do
      %{
        conversation: %{
          pending_interaction: %{id: id, request: %{approval_id: ^approval} = request}
        }
      } ->
        {:ok, %{type: :interaction_requested, interaction_id: id, request: request}}

      %{phase: phase} when phase in [:terminal, :storage_failed, :recovery_required] ->
        failure(:cancelled, "Permission request ended")

      _ ->
        receive do
        after
          10 -> await_permission(pid, approval, remaining - 1)
        end
    end
  end

  defp remember_permission(state, pid, event) do
    request = event.request
    identity = get_in(state.runs, [request.run_id, :identity]) || %{name: "/root"}

    host = %{
      session_id: state.session_id,
      run_id: request.run_id,
      policy_snapshot:
        policy(
          get_in(state.runs, [request.run_id, :context]) || state.context,
          state.session_id,
          request.run_id
        )
    }

    item = %{pid: pid, request: request, host: host}
    notify(state, {:runtime_event, state.epoch, state.run_id, Map.put(event, :child, identity)})
    %{state | pending: Map.put(state.pending, event.interaction_id, item)}
  end

  defp forget_run_permissions(state, run_id) do
    {closed, pending} =
      Enum.split_with(state.pending, fn {_, item} -> item.request.run_id == run_id end)

    Enum.each(closed, fn {id, _} ->
      notify(
        state,
        {:runtime_event, state.epoch, state.run_id,
         %{type: :interaction_resolved, interaction_id: id}}
      )
    end)

    %{state | pending: Map.new(pending)}
  end

  defp approval(request, host, decision) when decision in [true, :allow, "allow_once"] do
    with {:ok, grant} <-
           Gateway.authorize(
             request.tool_name,
             request.arguments,
             host.policy_snapshot,
             Map.put(host, :operator_approval, true)
           ),
         true <- grant.source == :operator_approval do
      %{approval_id: request.approval_id, grant: grant}
    else
      _ -> %{approval_id: request.approval_id, denied: true}
    end
  end

  defp approval(request, _host, _decision), do: %{approval_id: request.approval_id, denied: true}

  defp close(%{closing: true} = state), do: state
  defp close(%{error: :closed} = state), do: state

  defp close(state) do
    if is_pid(state.session) do
      job(%{state | closing: true}, :close, fn ->
        # The root can already be retired by an in-flight terminal status job.
        # A vanished root must not prevent closing its session-owned children.
        if is_pid(state.root), do: safe(fn -> Conversation.cancel(state.root) end)
        cleanup = Session.close(state.session)
        history = closed_history(state)
        stop(state.root)
        %{cleanup: cleanup, history: history}
      end)
    else
      if state.busy, do: %{state | closing: true}, else: cancelled_without_runtime(state)
    end
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
    persist_roster(%{state | roster: Map.put(state.roster, :root, root)})
  end

  defp unknown(roster) do
    roster
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

  defp stop(pid) when is_pid(pid) do
    Process.unlink(pid)
    if Process.alive?(pid), do: GenServer.stop(pid, :shutdown, 10_000)
  catch
    :exit, _ -> Process.exit(pid, :kill)
  end

  defp stop(_), do: :ok
  defp notify(state, event), do: send(state.owner, event)
  defp failure(class, message), do: {:error, Error.new(class, message)}
end
