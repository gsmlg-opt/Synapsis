defmodule Synapsis.Session.Worker do
  @moduledoc """
  Per-session `:gen_statem` coordinating the native runtime and shared session I/O.

  Both session modes start turns through `Worker.Runtime`. The Worker owns prompt
  queues, shared user questions and live session metadata; Backplane owns turn
  execution. Historical engine fields remain compatibility metadata, parked at
  `:receive` with `awaiting_input: true`, without an executable session graph.

  The machine state is derived from runtime and compatibility fields after each
  event. Boot schedules recovered prompts only after the Worker is registered.
  Native runtime events carry their runtime epoch. Shared user questions retain
  the Worker's epoch and owner-monitor lifecycle.
  """
  @behaviour :gen_statem
  require Logger

  alias Synapsis.Session.Stream, as: SessionStream

  alias Synapsis.Session.Worker.{
    Automation,
    Boot,
    Config,
    GoalHost,
    PendingInputs,
    Persistence,
    SuggestedTurn
  }

  alias Synapsis.Session.Worker.Runtime, as: RuntimeSession
  alias Synapsis.Agent.Graphs.CodingLoop
  alias Synapsis.Agent.ResponseFlusher

  @timeout :timer.minutes(30)

  @doc "Session inactivity timeout value."
  def timeout, do: @timeout

  defstruct [
    :session_id,
    :session,
    :agent,
    :provider_config,
    # Historical engine metadata; graph remains nil.
    :graph,
    :engine_node,
    :engine_state,
    :engine_ctx,
    :epoch,
    # I/O state
    :stream_ref,
    :project_path,
    :debug_handler_id,
    stream_acc: Synapsis.Agent.StreamAccumulator.new(),
    pending_tool_count: 0,
    pending_approvals: MapSet.new(),
    approval_decisions: %{},
    user_questions: %{},
    execution_mode: :graph,
    query_loop_task: nil,
    mcp_refresh_task: nil,
    mcp_refresh_timer: nil,
    runtime_pid: nil,
    runtime_ref: nil,
    runtime_epoch: nil,
    runtime_run_id: nil,
    runtime_active: false,
    runtime_task: nil,
    runtime_phase: nil,
    runtime_cancelled: false,
    runtime_pending_terminal: nil,
    runtime_history: nil,
    runtime_history_offset: 0,
    runtime_turn_offset: 0,
    runtime_history_error: nil,
    reply_presentation: nil,
    automation_reads: %{},
    automation_pending: [],
    automation_task: nil,
    automation_uncertain: false,
    pending_inputs: nil,
    suggested_turn: nil,
    runtime_roster: %{agents: []},
    runtime_permissions: [],
    runtime_questions: [],
    checkpoints: [],
    # Historical task/result bookkeeping retained as compatibility metadata.
    tool_tasks: %{},
    # Historical tool IDs retained as compatibility metadata.
    executed_tool_ids: MapSet.new()
  ]

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker
    }
  end

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    :gen_statem.start_link(via(session_id), __MODULE__, opts, [])
  end

  def send_message(session_id, content, image_parts \\ []),
    do: :gen_statem.call(via(session_id), {:send_message, content, image_parts}, 30_000)

  def send_message(session_id, content, image_parts, input_context),
    do:
      :gen_statem.call(
        via(session_id),
        {:send_message, content, image_parts, input_context},
        30_000
      )

  @doc "Start one fresh suggested turn and acknowledge checkpointed native consumption."
  def start_suggested_turn(session_id, request, opts \\ []),
    do: SuggestedTurn.request(session_id, request, opts)

  def steer_message(session_id, content),
    do: :gen_statem.call(via(session_id), {:steer_message, content}, 30_000)

  def cancel(session_id), do: :gen_statem.cast(via(session_id), :cancel)
  def retry(session_id), do: :gen_statem.call(via(session_id), :retry, 30_000)

  def regenerate(session_id, message_id),
    do: :gen_statem.call(via(session_id), {:regenerate, message_id}, 30_000)

  def push_checkpoint(session_id, reason \\ nil),
    do: :gen_statem.call(via(session_id), {:push_checkpoint, reason}, 10_000)

  def rollback_checkpoint(session_id, reason \\ nil),
    do: :gen_statem.call(via(session_id), {:rollback_checkpoint, reason}, 30_000)

  def approve_tool(session_id, id), do: :gen_statem.cast(via(session_id), {:approve_tool, id})
  def deny_tool(session_id, id), do: :gen_statem.cast(via(session_id), {:deny_tool, id})

  def switch_agent(session_id, n),
    do: :gen_statem.call(via(session_id), {:switch_agent, n}, 10_000)

  def switch_model(session_id, p, m),
    do: :gen_statem.call(via(session_id), {:switch_model, p, m}, 10_000)

  def switch_mode(session_id, mode),
    do: :gen_statem.call(via(session_id), {:switch_mode, mode}, 10_000)

  def get_status(session_id), do: :gen_statem.call(via(session_id), :get_status, 10_000)

  @doc "Bounded exact-session context; an absent Worker uses a supervised durable reader."
  def automation_context(session_id, opts \\ []) do
    with {:ok, deadline} <- public_status_deadline(opts),
         :ok <- public_status_remaining(deadline) do
      case Registry.lookup(Synapsis.Session.Registry, session_id) do
        [{_pid, _}] ->
          :gen_statem.call(
            via(session_id),
            {:automation_context, deadline},
            max(deadline - public_status_now(), 1)
          )

        [] ->
          task =
            Task.Supervisor.async_nolink(Synapsis.Tool.TaskSupervisor, fn ->
              Automation.durable_context(session_id, deadline)
            end)

          case Task.yield(task, max(deadline - public_status_now(), 1)) do
            {:ok, result} ->
              result

            _ ->
              Task.shutdown(task, :brutal_kill)
              {:error, :context_unavailable}
          end
      end
    end
  catch
    :exit, _ -> {:error, :context_unavailable}
  end

  @doc "Serialize a completed assistant turn without starting a provider request."
  def append_automation_result(session_id, text, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 15_000)

    if is_binary(text) and is_integer(timeout) and timeout > 0 do
      :gen_statem.call(via(session_id), {:append_automation_result, text}, min(timeout, 30_000))
    else
      {:error, :invalid_input}
    end
  catch
    :exit, _ -> {:error, :unknown_outcome}
  end

  @doc "Stage an owned event in this exact Worker before acknowledging acceptance."
  def wake(session_id, text, opts) do
    deadline = Keyword.fetch!(opts, :deadline)
    remaining = deadline - public_status_now()

    if remaining > 0,
      do: :gen_statem.call(via(session_id), {:wake, text, opts}, remaining),
      else: {:error, :timeout}
  catch
    :exit, _ -> {:error, :unknown_outcome}
  end

  @doc false
  def stage_music_completion(session_id, attrs, opts) do
    remaining = Keyword.fetch!(opts, :deadline) - public_status_now()

    if remaining > 0,
      do: :gen_statem.call(via(session_id), {:music_completion, attrs, opts}, remaining),
      else: {:error, :timeout}
  catch
    :exit, _ -> {:error, :unknown_outcome}
  end

  @doc false
  def apply_music_completion(session_id, event_id, payload) do
    remaining = payload.deadline - public_status_now()

    if remaining > 0,
      do:
        :gen_statem.call(via(session_id), {:apply_music_completion, event_id, payload}, remaining),
      else: {:error, :timeout}
  catch
    :exit, _ -> {:error, :unknown_outcome}
  end

  @doc """
  Bounded live public observation of Worker-owned metadata and runtime flags.
  Phase is the coarse actual statem state; active is the native runtime flag.
  Shares a caller deadline capped at five seconds, without storage or provider I/O.
  Renews the existing inactivity timeout like other Worker reads; no state is changed.
  """
  def public_status(session_id, opts \\ []) do
    with true <- is_binary(session_id) and match?({:ok, ^session_id}, Ecto.UUID.cast(session_id)),
         {:ok, deadline} <- public_status_deadline(opts),
         :ok <- public_status_remaining(deadline),
         result <-
           :gen_statem.call(
             via(session_id),
             {:public_status, deadline},
             max(deadline - public_status_now(), 1)
           ),
         :ok <- public_status_remaining(deadline) do
      result
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  catch
    :exit, {:noproc, _} -> {:error, :not_running}
    :exit, :noproc -> {:error, :not_running}
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :unavailable}
  end

  defp public_status_deadline(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:deadline] == [] and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) do
      ceiling = public_status_now() + 5_000
      value = Keyword.get(opts, :deadline, ceiling)
      if is_integer(value), do: {:ok, min(value, ceiling)}, else: {:error, :invalid_input}
    else
      {:error, :invalid_input}
    end
  end

  defp public_status_deadline(_), do: {:error, :invalid_input}

  defp public_status_remaining(deadline),
    do: if(deadline > public_status_now(), do: :ok, else: {:error, :timeout})

  defp public_status_now, do: System.monotonic_time(:millisecond)

  def answer_question(session_id, ref, response),
    do: :gen_statem.call(via(session_id), {:answer_question, ref, response}, 10_000)

  @doc """
  Live read snapshot of the session (ADR-006 B2): the process is the read
  authority during a turn. Returns the current status, session record, and the
  in-flight assistant text accumulated so far this turn.
  """
  def snapshot(session_id), do: :gen_statem.call(via(session_id), :snapshot, 10_000)

  def set_subagents(session_id, enabled),
    do: :gen_statem.call(via(session_id), {:set_subagents, enabled}, 10_000)

  def resolve_runtime(session_id, interaction_id, decision),
    do: :gen_statem.call(via(session_id), {:resolve_runtime, interaction_id, decision}, 10_000)

  defp via(id), do: {:via, Registry, {Synapsis.Session.Registry, id}}

  @impl :gen_statem
  def callback_mode, do: :handle_event_function

  @impl :gen_statem
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    try do
      case Boot.load_and_boot(session_id) do
        {:stop, reason} ->
          record_boot_failure(session_id)
          {:stop, reason}

        {session, agent, pc, graph, engine_state, engine_ctx, project_path} ->
          # Successful boot clears the poison-protection failure counter.
          Synapsis.Session.Quarantine.clear(session.id)
          Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session.id}")
          Logger.info("session_worker_started", session_id: session.id)

          data = %__MODULE__{
            session_id: session.id,
            session: session,
            agent: agent,
            provider_config: pc,
            graph: graph,
            engine_node: :receive,
            engine_state: engine_state,
            engine_ctx: engine_ctx,
            # New monotonic epoch each (re)boot — fences stale task results and
            # satisfies the ADR-006 "bump epoch on rehydrate" rule.
            epoch: new_epoch(),
            project_path: project_path,
            runtime_roster: RuntimeSession.initial_roster(session.id),
            pending_inputs: PendingInputs.new()
          }

          # Drain recovered prompts after init so the Worker is registered first.
          {:ok, :booting, data, [{:next_event, :internal, :resume_pending_inputs}]}
      end
    rescue
      e ->
        # A crash in init/rehydrate (e.g. corrupt snapshot) counts toward poison
        # protection, then re-raises so the supervisor's restart budget applies.
        record_boot_failure(session_id)
        reraise e, __STACKTRACE__
    end
  end

  defp record_boot_failure(session_id) do
    case Synapsis.Session.Quarantine.record_failure(session_id) do
      {:quarantined, count} ->
        Logger.error("session_quarantined", session_id: session_id, failures: count)

      _ ->
        :ok
    end
  end

  @impl :gen_statem
  def handle_event(:internal, :resume_pending_inputs, :booting, data) do
    {data, actions} = PendingInputs.boot(data)
    advance(data, actions)
  end

  def handle_event(
        {:call, _from},
        {:start_suggested_turn, _request, _deadline},
        _state,
        %{pending_inputs: %{booted: false, blocked: false}}
      ),
      do: {:keep_state_and_data, [:postpone]}

  def handle_event({:call, from}, {:start_suggested_turn, request, deadline}, _state, data) do
    {data, actions} = SuggestedTurn.start(data, request, from, deadline)
    advance(data, actions)
  end

  def handle_event({:call, from}, {:automation_context, deadline}, _state, data),
    do: advance(Automation.start_context(data, from, deadline))

  def handle_event(
        {:call, from},
        {:goal_host, context, thread_id, operation, request},
        _state,
        data
      ) do
    reply = GoalHost.reply(data, context, thread_id, operation, request)
    keep(data, [{:reply, from, reply}])
  end

  def handle_event({:call, from}, {:append_automation_result, text}, _state, data) do
    {data, actions} = Automation.enqueue(data, text, from)
    advance(data, actions)
  end

  def handle_event({:call, from}, {:music_completion, attrs, opts}, _state, data) do
    {data, actions} = PendingInputs.music_completion(data, attrs, opts, from)
    advance(data, actions)
  end

  def handle_event({:call, from}, {:apply_music_completion, event_id, payload}, _state, data) do
    {data, actions} = PendingInputs.apply_music_completion(data, event_id, payload, from)
    advance(data, actions)
  end

  def handle_event({:call, from}, {:wake, text, opts}, _state, data) do
    {data, actions} = PendingInputs.wake(data, text, opts, from)
    advance(data, actions)
  end

  def handle_event({:call, from}, {:send_message, content, image_parts}, _state, data) do
    {data, actions} = PendingInputs.prompt(data, content, image_parts, from)
    advance(data, actions)
  end

  def handle_event(
        {:call, from},
        {:send_message, content, image_parts, input_context},
        _state,
        data
      ) do
    case Synapsis.Session.InputContext.validate(input_context, data.session_id) do
      :ok ->
        {data, actions} = PendingInputs.prompt(data, content, image_parts, from, input_context)
        advance(data, actions)

      error ->
        keep(data, [{:reply, from, error}])
    end
  end

  def handle_event(
        {:call, from},
        {:steer_message, content},
        _state,
        %{runtime_active: true, runtime_phase: :running, runtime_pid: pid} = data
      )
      when is_pid(pid) do
    :ok = Synapsis.Agent.Runtime.SessionAdapter.input(pid, content)
    keep(data, [{:reply, from, :ok}])
  end

  def handle_event(
        {:call, from},
        {:steer_message, _content},
        _state,
        %{runtime_active: true} = data
      ),
      do: keep(data, [{:reply, from, {:error, :turn_not_ready}}])

  def handle_event({:call, from}, {:steer_message, content}, state, data) do
    case {data.execution_mode, state} do
      {:graph, :idle} ->
        keep(data, [{:reply, from, {:error, :no_active_turn}}])

      {:graph, _running} ->
        if data.runtime_active do
          :ok = Synapsis.Agent.Runtime.SessionAdapter.input(data.runtime_pid, content)
          keep(data, [{:reply, from, :ok}])
        else
          {data, actions} = PendingInputs.steer(data, content, from)
          advance(data, actions)
        end

      {:query_loop, _} ->
        keep(data, [{:reply, from, {:error, :no_active_turn}}])
    end
  end

  def handle_event({:call, from}, :retry, _state, data),
    do: keep(data, [{:reply, from, {:error, :retry_unavailable_with_subagents}}])

  def handle_event({:call, from}, {:regenerate, _message_id}, _state, data),
    do: keep(data, [{:reply, from, {:error, :regenerate_unavailable_with_subagents}}])

  def handle_event({:call, from}, request, _state, data)
      when is_tuple(request) and elem(request, 0) in [:push_checkpoint, :rollback_checkpoint],
      do: keep(data, [{:reply, from, {:error, :checkpoint_unavailable_with_subagents}}])

  def handle_event({:call, from}, :get_status, state, data) do
    keep(data, [{:reply, from, external_status(state)}])
  end

  def handle_event({:call, from}, {:public_status, deadline}, state, data) do
    result =
      with :ok <- public_status_remaining(deadline),
           {:ok, session} <-
             Synapsis.SessionStatus.project(
               Synapsis.Session.to_meta(data.session),
               data.session_id
             ),
           result = %{
             source: "live",
             session: Map.delete(session, :status),
             runtime: %{
               status:
                 if(state == :idle and not is_nil(data.runtime_history_error),
                   do: "error",
                   else: Atom.to_string(external_status(state))
                 ),
               phase: Atom.to_string(state),
               active: data.runtime_active
             }
           },
           {:ok, json} <- Jason.encode(result),
           true <- byte_size(json) <= 65_536,
           :ok <- public_status_remaining(deadline) do
        {:ok, result}
      else
        false -> {:error, :output_limit}
        {:error, reason} when is_atom(reason) -> {:error, reason}
        _ -> {:error, :malformed_metadata}
      end

    keep(data, [{:reply, from, result}])
  end

  def handle_event({:call, from}, :snapshot, state, data) do
    data = prune_user_questions(data)

    snapshot = %{
      source: :live,
      status:
        if(state == :idle and not is_nil(data.runtime_history_error),
          do: :error,
          else: external_status(state)
        ),
      error: RuntimeSession.error_message(data),
      session: data.session,
      in_flight_text: Map.get(data.stream_acc, :pending_text, ""),
      reply_presentation: RuntimeSession.reply_presentation(data),
      subagents: data.runtime_roster,
      runtime_permissions: data.runtime_permissions,
      user_questions:
        data
        |> Map.get(:user_questions, %{})
        |> Enum.sort_by(fn {ref, _question} -> ref end)
        |> Enum.map(fn {_ref, question} -> Map.take(question, [:ref, :question, :options]) end)
        |> Kernel.++(RuntimeSession.questions(data))
    }

    {:keep_state, data, [{:reply, from, snapshot}, timeout_action()]}
  end

  def handle_event({:call, from}, {:set_subagents, enabled}, :idle, data)
      when is_boolean(enabled) do
    active_children? =
      Enum.any?(Map.get(data.runtime_roster, :agents, []), fn agent ->
        agent[:status] not in [
          :completed,
          :errored,
          :interrupted,
          :closed,
          :shutdown,
          "completed",
          "errored",
          "interrupted",
          "closed",
          "shutdown"
        ]
      end)

    cond do
      data.runtime_roster[:recovery_required] || data.runtime_roster[:error] ->
        keep(data, [{:reply, from, {:error, :recovery_required}}])

      active_children? ->
        keep(data, [{:reply, from, {:error, :subagents_active}}])

      true ->
        session = %{
          data.session
          | config: Map.put(data.session.config || %{}, "subagents", enabled)
        }

        case Synapsis.Session.Store.put_meta(session.id, Synapsis.Session.to_meta(session)) do
          :ok -> advance(%{data | session: session}, [{:reply, from, {:ok, session}}])
          {:error, reason} -> keep(data, [{:reply, from, {:error, reason}}])
        end
    end
  end

  def handle_event({:call, from}, {:set_subagents, enabled}, _state, data) do
    reason = if is_boolean(enabled), do: :session_busy, else: :invalid_setting
    keep(data, [{:reply, from, {:error, reason}}])
  end

  def handle_event({:call, from}, {:resolve_runtime, id, decision}, _state, data) do
    case RuntimeSession.resolve(data, id, decision) do
      {:ok, data} -> advance(data, [{:reply, from, :ok}])
      {:error, reason} -> keep(data, [{:reply, from, {:error, reason}}])
    end
  end

  def handle_event({:call, from}, {:answer_question, ref, response}, _state, data) do
    data = prune_user_questions(data)

    {result, data} =
      cond do
        not is_binary(response) or String.trim(response) == "" ->
          {{:error, :invalid_response}, data}

        RuntimeSession.question_pending?(data, ref) ->
          case RuntimeSession.answer_question(data, ref, response) do
            {:ok, data} -> {:ok, data}
            {:error, reason} -> {{:error, reason}, data}
          end

        not Map.has_key?(Map.get(data, :user_questions, %{}), ref) ->
          {{:error, :question_not_pending}, data}

        true ->
          Phoenix.PubSub.broadcast(
            Synapsis.PubSub,
            "ask_user_response:#{data.session_id}",
            {:user_response, ref, response}
          )

          {:ok, close_user_question(data, ref)}
      end

    {:keep_state, data, [{:reply, from, result}, timeout_action()]}
  end

  def handle_event({:call, from}, request, _state, %{runtime_active: true} = data)
      when is_tuple(request) and elem(request, 0) in [:switch_agent, :switch_model, :switch_mode],
      do: keep(data, [{:reply, from, {:error, :session_busy}}])

  def handle_event({:call, from}, {:switch_model, _provider, _model}, status, data)
      when status != :idle,
      do: keep(data, [{:reply, from, {:error, :session_busy}}])

  def handle_event({:call, from}, {:switch_agent, name}, _state, data) do
    if PendingInputs.changing_agent?(data) do
      keep(data, [{:reply, from, {:error, :session_busy}}])
    else
      switch_agent(data, name, from)
    end
  end

  def handle_event({:call, from}, {:switch_model, prov, model}, _state, data) do
    case Config.do_switch_model(prov, model, data) do
      {:ok, session, pc, agent} ->
        Persistence.broadcast(data.session_id, "model_switched", %{
          provider: prov,
          model: model
        })

        advance(Config.update_model_state(data, session, pc, agent), [
          {:reply, from, :ok}
        ])

      {:error, reason} ->
        keep(data, [{:reply, from, {:error, reason}}])
    end
  end

  def handle_event({:call, from}, {:switch_mode, mode}, _state, data) do
    case Config.apply_mode(mode, data) do
      # execution_mode may change — re-derive the state.
      {:ok, d} -> advance(d, [{:reply, from, :ok}])
      {:error, r} -> keep(data, [{:reply, from, {:error, r}}])
    end
  end

  def handle_event(:cast, :cancel, _state, data) do
    data = cancel_user_questions(data)
    {data, actions} = PendingInputs.cancel_steers(data)

    if is_pid(data.runtime_pid) and RuntimeSession.enabled?(data) do
      advance(RuntimeSession.cancel(data), actions)
    else
      cancel_without_runtime(data, actions)
    end
  end

  def handle_event(:cast, {:approve_tool, id}, _state, data),
    do: collect_approval(data, id, :approved)

  def handle_event(:cast, {:deny_tool, id}, _state, data),
    do: collect_approval(data, id, :denied)

  def handle_event(
        :info,
        {:runtime_started, epoch, run_id},
        _state,
        %{
          runtime_epoch: epoch,
          runtime_active: true,
          runtime_phase: :running,
          runtime_run_id: nil
        } = data
      ),
      do: advance(RuntimeSession.started(data, run_id))

  def handle_event(
        :info,
        {:runtime_roster, epoch, roster},
        _state,
        %{runtime_epoch: epoch} = data
      ),
      do: advance(RuntimeSession.roster(data, roster))

  def handle_event(
        :info,
        {:runtime_history, epoch, run_id, history},
        _state,
        %{runtime_epoch: epoch, runtime_run_id: run_id} = data
      ),
      do: advance(RuntimeSession.history(data, history))

  def handle_event(
        :info,
        {:runtime_event, epoch, _run_id, %{type: type} = event},
        _state,
        %{runtime_epoch: epoch} = data
      )
      when type in [:interaction_requested, :interaction_resolved],
      do: advance(RuntimeSession.event(data, event))

  def handle_event(
        :info,
        {:runtime_event, epoch, run_id, event},
        _state,
        %{runtime_epoch: epoch, runtime_run_id: run_id} = data
      ) do
    data = RuntimeSession.event(data, event)
    advance(data)
  end

  def handle_event(
        :info,
        {:runtime_admission_failed, epoch, reason},
        _state,
        %{runtime_epoch: epoch} = data
      ),
      do: advance(RuntimeSession.fail(data, reason))

  def handle_event(
        :info,
        {ref, result},
        _state,
        %{pending_inputs: %{task: %{task: %Task{ref: ref}}}} = data
      ) do
    Process.demonitor(ref, [:flush])
    {data, actions} = PendingInputs.result(data, result)
    advance(data, actions)
  end

  def handle_event(
        :info,
        {:DOWN, ref, :process, _pid, _reason},
        _state,
        %{pending_inputs: %{task: %{task: %Task{ref: ref}}}} = data
      ) do
    {data, actions} = PendingInputs.result(data, {:error, :unknown_outcome})
    advance(data, actions)
  end

  def handle_event(
        :info,
        {:pending_input_timeout, ref},
        _state,
        %{pending_inputs: %{task: %{task: %Task{ref: ref}}}} = data
      ) do
    {data, actions} = PendingInputs.timeout(data)
    advance(data, actions)
  end

  def handle_event(:info, {:suggested_turn_timeout, claim_id}, _state, data),
    do: advance(SuggestedTurn.timeout(data, claim_id))

  def handle_event(
        :info,
        {:DOWN, ref, :process, _pid, _reason},
        _state,
        %{suggested_turn: %{monitor: ref, status: :preparing}} = data
      )
      when is_reference(ref),
      do: advance(SuggestedTurn.caller_down(data, ref))

  def handle_event(:info, {:pending_input_timeout, _ref}, _state, data), do: keep(data)

  def handle_event(:info, {ref, result}, _state, %{runtime_task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])

    case RuntimeSession.task_result(data, result) do
      {:ok, data} ->
        advance(data)

      {:error, data} ->
        advance(data)
    end
  end

  def handle_event(
        :info,
        {ref, result},
        _state,
        %{automation_task: %{task: %Task{ref: ref}}} = data
      ) do
    Process.demonitor(ref, [:flush])
    {data, actions} = Automation.append_result(data, result)
    advance(data, actions)
  end

  def handle_event(:info, {ref, result}, _state, data)
      when is_map_key(data.automation_reads, ref) do
    Process.demonitor(ref, [:flush])
    {data, actions} = Automation.context_result(data, ref, result)
    advance(data, actions)
  end

  def handle_event(
        :info,
        {:DOWN, ref, :process, _pid, _reason},
        _state,
        %{automation_task: %{task: %Task{ref: ref}}} = data
      ) do
    {data, actions} = Automation.append_result(data, {:error, :unknown_outcome})
    advance(data, actions)
  end

  def handle_event(:info, {:DOWN, ref, :process, _pid, _reason}, _state, data)
      when is_map_key(data.automation_reads, ref) do
    {data, actions} = Automation.context_result(data, ref, {:error, :context_unavailable})
    advance(data, actions)
  end

  def handle_event(
        :info,
        {:DOWN, ref, :process, _pid, reason},
        _state,
        %{runtime_task: %Task{ref: ref}} = data
      ),
      do:
        advance(RuntimeSession.fail(%{data | runtime_task: nil}, {:runtime_task_failed, reason}))

  def handle_event(
        :info,
        {:DOWN, ref, :process, _pid, reason},
        _state,
        %{runtime_ref: ref} = data
      )
      when is_reference(ref) do
    data = %{data | runtime_pid: nil, runtime_ref: nil, runtime_epoch: nil}

    data =
      if data.runtime_active,
        do: RuntimeSession.fail(data, {:runtime_stopped, reason}),
        else: data

    advance(data)
  end

  def handle_event(:info, message, _state, data)
      when is_tuple(message) and
             elem(message, 0) in [
               :runtime_started,
               :runtime_roster,
               :runtime_history,
               :runtime_event,
               :runtime_admission_failed
             ],
      do: keep(data)

  # User question events shared by native runtime and legacy tool callers
  def handle_event(
        :info,
        {:ask_user, ref, %{owner: owner, session_epoch: epoch} = payload},
        _state,
        %{epoch: current_epoch} = data
      )
      when is_binary(ref) and is_pid(owner) and not is_nil(epoch) and epoch != current_epoch do
    if Map.get(payload, :session_id, data.session_id) == data.session_id do
      send(owner, {:ask_user_cancelled, ref})

      Phoenix.PubSub.broadcast(
        Synapsis.PubSub,
        "session:#{data.session_id}",
        {:ask_user_closed, ref}
      )
    end

    {:keep_state, data, [timeout_action()]}
  end

  def handle_event(
        :info,
        {:ask_user, ref, %{owner: owner, deadline_ms: deadline} = payload},
        _state,
        data
      )
      when is_binary(ref) and is_pid(owner) and is_integer(deadline) do
    data = prune_user_questions(data)

    data =
      if Process.alive?(owner) and deadline > System.monotonic_time(:millisecond) and
           Map.get(payload, :session_id, data.session_id) == data.session_id do
        questions = Map.get(data, :user_questions, %{})

        if Map.has_key?(questions, ref) do
          data
        else
          question =
            payload
            |> Map.take([:question, :options])
            |> Map.merge(%{
              ref: ref,
              owner: owner,
              deadline_ms: deadline,
              monitor: Process.monitor(owner),
              timer:
                Process.send_after(
                  self(),
                  {:ask_user_expired, ref},
                  max(deadline - System.monotonic_time(:millisecond), 0)
                )
            })

          # Repeat only the public notification after registration so subscribers
          # can safely refresh the authoritative snapshot regardless of delivery order.
          Phoenix.PubSub.broadcast(
            Synapsis.PubSub,
            "session:#{data.session_id}",
            {:ask_user, ref,
             Map.put(
               Map.take(question, [:ref, :question, :options]),
               :session_id,
               data.session_id
             )}
          )

          Map.put(data, :user_questions, Map.put(questions, ref, question))
        end
      else
        data
      end

    {:keep_state, data, [timeout_action()]}
  end

  def handle_event(:info, {:ask_user, _ref, _payload}, _state, data),
    do: {:keep_state, data, [timeout_action()]}

  def handle_event(:info, {:ask_user_closed, ref}, _state, data),
    do: {:keep_state, close_user_question(data, ref), [timeout_action()]}

  def handle_event(:info, {:ask_user_expired, ref}, _state, data),
    do: {:keep_state, close_user_question(data, ref), [timeout_action()]}

  # Shared question-owner monitor cleanup.
  def handle_event(:info, {:DOWN, ref, :process, _pid, _reason}, _state, data)
      when is_reference(ref) do
    data =
      case Enum.find(Map.get(data, :user_questions, %{}), fn {_id, q} -> q.monitor == ref end) do
        {question_ref, _question} -> close_user_question(data, question_ref)
        nil -> data
      end

    {:keep_state, data, [timeout_action()]}
  end

  def handle_event(:timeout, :inactivity, _state, data) do
    Logger.info("session_inactivity_timeout", session_id: data.session_id)
    Persistence.update_session_status(data.session_id, "idle")
    {:stop, :normal}
  end

  def handle_event(:info, _msg, _state, data), do: keep(data)

  @impl :gen_statem
  def terminate(reason, _state, data) do
    cancel_user_questions(data)
    Automation.stop(data)
    PendingInputs.stop(data)
    if data.runtime_task, do: Task.shutdown(data.runtime_task, :brutal_kill)
    if data.query_loop_task, do: Task.shutdown(data.query_loop_task, :brutal_kill)

    if is_pid(data.runtime_pid),
      do: Synapsis.Agent.Runtime.SessionAdapter.cancel(data.runtime_pid)

    Logger.info("session_worker_terminated",
      session_id: data.session_id,
      reason: inspect(reason)
    )

    case Synapsis.Swarm.delete_team(data.session_id) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("session_swarm_cleanup_failed",
          session_id: data.session_id,
          reason: reason
        )
    end

    :ok
  end

  # --- State machine helpers ---

  @doc """
  Derive the machine state from the data. Called after every event so the
  state can never disagree with the runtime/compatibility fields it summarizes.
  """
  def derive_state(%__MODULE__{} = d) do
    cond do
      d.runtime_active and (d.runtime_permissions != [] or d.runtime_questions != []) ->
        :awaiting_approval

      d.runtime_active ->
        :generating

      PendingInputs.busy?(d) ->
        :busy

      not is_nil(d.automation_task) ->
        :busy

      d.automation_uncertain ->
        :busy

      d.execution_mode == :query_loop and d.query_loop_task != nil ->
        :query_loop

      MapSet.size(d.pending_approvals) > 0 ->
        :awaiting_approval

      d.stream_ref != nil ->
        :generating

      d.pending_tool_count > 0 ->
        :executing_tools

      engine_ready?(d) ->
        :idle

      true ->
        :busy
    end
  end

  defp advance(%__MODULE__{} = data, actions \\ []) do
    data = Automation.start_next(data)
    {data, pending_actions} = PendingInputs.advance(data)
    {:next_state, derive_state(data), data, actions ++ pending_actions ++ [timeout_action()]}
  end

  defp keep(%__MODULE__{} = _data, actions \\ []) do
    {:keep_state_and_data, actions ++ [timeout_action()]}
  end

  defp timeout_action, do: {:timeout, @timeout, :inactivity}

  defp external_status(:idle), do: :waiting
  defp external_status(_state), do: :running

  @doc "True when compatibility metadata is parked at :receive waiting for user input."
  def engine_ready?(%__MODULE__{engine_node: node, engine_state: es}) do
    node == :receive and Map.get(es, :awaiting_input, false)
  end

  # --- Private helpers ---

  defp prune_user_questions(data) do
    now = System.monotonic_time(:millisecond)

    Enum.reduce(Map.get(data, :user_questions, %{}), data, fn {ref, question}, data ->
      if question.deadline_ms <= now or not Process.alive?(question.owner),
        do: close_user_question(data, ref),
        else: data
    end)
  end

  defp close_user_question(data, ref) do
    {question, questions} = Map.pop(Map.get(data, :user_questions, %{}), ref)

    if question do
      Process.demonitor(question.monitor, [:flush])
      Process.cancel_timer(question.timer)

      Phoenix.PubSub.broadcast(
        Synapsis.PubSub,
        "session:#{data.session_id}",
        {:ask_user_closed, ref}
      )
    end

    Map.put(data, :user_questions, questions)
  end

  defp cancel_user_questions(data) do
    Enum.reduce(Map.get(data, :user_questions, %{}), data, fn {ref, question}, data ->
      send(question.owner, {:ask_user_cancelled, ref})
      close_user_question(data, ref)
    end)
  end

  defp new_epoch, do: System.monotonic_time()

  defp reset_engine_state(state) do
    %{
      session_id: state.session_id,
      provider_config: state.provider_config,
      agent_config: state.agent
    }
    |> CodingLoop.initial_state()
    |> Map.put(:awaiting_input, true)
  end

  defp switch_agent(data, name, from) do
    case Config.do_switch_agent(name, data.session) do
      {:ok, agent, session} ->
        Persistence.broadcast(data.session_id, "agent_switched", %{agent: to_string(name)})

        {:keep_state, %{data | agent: agent, session: session},
         [{:reply, from, :ok}, timeout_action()]}

      {:error, reason} ->
        keep(data, [{:reply, from, {:error, reason}}])
    end
  end

  defp collect_approval(data, tool_use_id, decision) do
    decisions = Map.put(data.approval_decisions, tool_use_id, decision)
    data = %{data | approval_decisions: decisions}

    advance(data)
  end

  defp close_open_tool_uses(session_id) do
    _ = ResponseFlusher.ensure_tool_results(session_id, "Tool use cancelled by user.", true)
    :ok
  end

  defp cancel_without_runtime(data, actions) do
    case data.execution_mode do
      :query_loop ->
        if data.query_loop_task, do: Task.shutdown(data.query_loop_task, :brutal_kill)
        close_open_tool_uses(data.session_id)
        Persistence.set_status(data.session_id, "idle")
        advance(%{data | query_loop_task: nil}, actions)

      :graph ->
        if data.stream_ref,
          do:
            SessionStream.cancel_stream(
              data.stream_ref,
              data.agent[:provider] || data.session.provider
            )

        close_open_tool_uses(data.session_id)
        Persistence.set_status(data.session_id, "idle")

        # Reset compatibility metadata and fence surviving question owners.
        new_data = %{
          data
          | stream_ref: nil,
            epoch: new_epoch(),
            engine_state: reset_engine_state(data),
            engine_node: :receive,
            pending_tool_count: 0,
            pending_approvals: MapSet.new(),
            approval_decisions: %{},
            tool_tasks: %{},
            executed_tool_ids: MapSet.new()
        }

        advance(new_data, actions)
    end
  end
end
