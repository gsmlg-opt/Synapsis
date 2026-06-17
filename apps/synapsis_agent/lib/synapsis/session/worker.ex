defmodule Synapsis.Session.Worker do
  @moduledoc """
  Per-session `:gen_statem`. Owns the graph engine and all I/O state.

  The engine (pure functions in `Runtime.Engine`) is stepped inline — no
  separate Runner process, no cross-process resume dance. Long-running I/O
  (LLM streaming, tool execution) is delegated via messages to the Worker's
  mailbox and coordinated by IOHandler.

  ## States

  Session states are explicit (ADR-008, realizing the harness Phase 4 plan
  against the graph engine):

    * `:booting`           — engine not yet parked (init only)
    * `:idle`              — engine parked at `:receive`, awaiting user input
    * `:generating`        — provider stream in flight
    * `:executing_tools`   — tool tasks outstanding
    * `:awaiting_approval` — blocked on user permission decisions
    * `:busy`              — engine running between waits (compaction, auditor, …)
    * `:query_loop`        — assistant-mode turn delegated to a QueryLoop task

  The state is derived from the data after every event (`derive_state/1`), so
  the machine can never disagree with the engine. Event handlers use the state
  for policy: graph-mode user prompts start immediately in `:idle` and are
  queued while the graph is running; assistant-mode query-loop prompts queue
  behind the active turn.

  ## Epoch fencing

  Every boot assigns a new monotonic epoch. Tasks capture the epoch at spawn
  and stamp every result/chunk message. The Worker drops messages whose epoch
  does not match the current one, so results from a dead incarnation (surviving
  after a `rest_for_one` restart) are silently discarded.
  """
  @behaviour :gen_statem
  require Logger

  alias Synapsis.Session.Stream, as: SessionStream
  alias Synapsis.Session.Worker.{Boot, Checkpoint, Config, IOHandler, Persistence}
  alias Synapsis.Agent.Graphs.CodingLoop
  alias Synapsis.Agent.ResponseFlusher
  alias Synapsis.Agent.Runtime.Engine
  alias Synapsis.Session.PendingInputStore

  @timeout :timer.minutes(30)

  @doc "Inactivity timeout value — used by IOHandler to keep the timeout consistent."
  def timeout, do: @timeout

  defstruct [
    :session_id,
    :session,
    :agent,
    :provider_config,
    # Engine fields (replace runner_pid)
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
    execution_mode: :graph,
    query_loop_task: nil,
    checkpoints: [],
    # Map of task_ref => tool_use_id; allows error tool_result flush on abnormal task exit.
    tool_tasks: %{},
    # Set of tool_use_ids already executed this turn; guards against soft-retry re-execution.
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

  @doc """
  Live read snapshot of the session (ADR-006 B2): the process is the read
  authority during a turn. Returns the current status, session record, and the
  in-flight assistant text accumulated so far this turn.
  """
  def snapshot(session_id), do: :gen_statem.call(via(session_id), :snapshot, 10_000)

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
          recover_pending_inputs(session.id)
          Logger.info("session_worker_started", session_id: session.id)

          data = %__MODULE__{
            session_id: session.id,
            session: session,
            agent: agent,
            provider_config: pc,
            graph: graph,
            engine_node: graph.start,
            engine_state: engine_state,
            engine_ctx: engine_ctx,
            # New monotonic epoch each (re)boot — fences stale task results and
            # satisfies the ADR-006 "bump epoch on rehydrate" rule.
            epoch: new_epoch(),
            project_path: project_path
          }

          # Park the engine at :receive after init so the Worker is registered first.
          {:ok, :booting, data, [{:next_event, :internal, :init_engine}]}
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
  def handle_event(:internal, :init_engine, :booting, data) do
    advance(step_engine(data))
  end

  def handle_event({:call, from}, {:send_message, content, image_parts}, state, data) do
    case {data.execution_mode, state} do
      {:query_loop, :query_loop} ->
        data
        |> queue_prompt(content, image_parts)
        |> reply_queue_result(from, data)

      {:query_loop, _} ->
        case start_query_loop_turn(data, content, image_parts) do
          {:ok, new_data} -> advance(new_data, [{:reply, from, :ok}])
          {:error, reason} -> keep(data, [{:reply, from, {:error, reason}}])
        end

      {:graph, :idle} ->
        case start_graph_turn(data, content, image_parts) do
          {:ok, new_data} -> advance(new_data, [{:reply, from, :ok}])
          {:error, reason} -> keep(data, [{:reply, from, {:error, reason}}])
        end

      {:graph, _running} ->
        data
        |> queue_prompt(content, image_parts)
        |> reply_queue_result(from, data)
    end
  end

  def handle_event({:call, from}, {:steer_message, content}, state, data) do
    case {data.execution_mode, state} do
      {:graph, :idle} ->
        keep(data, [{:reply, from, {:error, :no_active_turn}}])

      {:graph, _running} ->
        data
        |> queue_steer(content)
        |> reply_queue_result(from, data)

      {:query_loop, _} ->
        keep(data, [{:reply, from, {:error, :no_active_turn}}])
    end
  end

  def handle_event({:call, from}, :retry, _state, data) do
    if Persistence.has_messages?(data.session_id) do
      Persistence.set_status(data.session_id, "streaming")
      advance(step_engine(data, drain_before?: false), [{:reply, from, :ok}])
    else
      keep(data, [{:reply, from, {:error, :no_messages}}])
    end
  end

  # Regenerate an assistant response: only valid while idle (engine parked at
  # :receive) in graph mode. Truncates the transcript to drop the target reply
  # and everything after, then drives the loop exactly like send_message's
  # idle branch — minus persisting a new user message, since the prompting
  # message is already in the (now trailing) transcript.
  def handle_event(
        {:call, from},
        {:regenerate, message_id},
        :idle,
        %{execution_mode: :graph} = data
      ) do
    case Persistence.truncate_to_regenerate(data.session_id, message_id) do
      {:ok, user_text} ->
        new_ctx =
          data.engine_ctx
          |> Map.put(:user_input, user_text)
          |> Map.put(:image_parts, [])

        Persistence.set_status(data.session_id, "streaming")

        new_data =
          step_engine(%{data | engine_ctx: new_ctx, executed_tool_ids: MapSet.new()},
            drain_before?: false
          )

        advance(new_data, [{:reply, from, :ok}])

      {:error, reason} ->
        keep(data, [{:reply, from, {:error, reason}}])
    end
  end

  def handle_event({:call, from}, {:regenerate, _message_id}, _state, data),
    do: keep(data, [{:reply, from, {:error, {:engine_not_ready, data.engine_node}}}])

  def handle_event({:call, from}, {:push_checkpoint, reason}, _state, data) do
    case Checkpoint.push(data, reason) do
      {:ok, new_data, checkpoint} ->
        advance(new_data, [{:reply, from, {:ok, checkpoint.id}}])

      {:error, reason} ->
        keep(data, [{:reply, from, {:error, reason}}])
    end
  end

  def handle_event(
        {:call, from},
        {:rollback_checkpoint, reason},
        _state,
        %{checkpoints: [_ | _]} = data
      ) do
    case Checkpoint.rollback(data, reason) do
      {:ok, new_data, checkpoint} ->
        advance(new_data, [{:reply, from, {:ok, checkpoint.id}}])

      {:error, reason} ->
        keep(data, [{:reply, from, {:error, reason}}])
    end
  end

  # An empty stack is a caller error at this boundary; Checkpoint itself has
  # no empty-stack clause (an internal rollback without a push must crash).
  def handle_event({:call, from}, {:rollback_checkpoint, _reason}, _state, data),
    do: keep(data, [{:reply, from, {:error, :no_checkpoint}}])

  def handle_event({:call, from}, :get_status, state, data) do
    keep(data, [{:reply, from, external_status(state)}])
  end

  def handle_event({:call, from}, :snapshot, state, data) do
    snapshot = %{
      source: :live,
      status: external_status(state),
      session: data.session,
      in_flight_text: Map.get(data.stream_acc, :pending_text, "")
    }

    keep(data, [{:reply, from, snapshot}])
  end

  def handle_event({:call, from}, {:switch_agent, name}, _state, data) do
    case Config.do_switch_agent(name, data.session) do
      {:ok, agent, session} ->
        Persistence.broadcast(data.session_id, "agent_switched", %{agent: to_string(name)})
        keep(%{data | agent: agent, session: session}, [{:reply, from, :ok}])

      {:error, reason} ->
        keep(data, [{:reply, from, {:error, reason}}])
    end
  end

  def handle_event({:call, from}, {:switch_model, prov, model}, _state, data) do
    case Config.do_switch_model(prov, model, data) do
      {:ok, session, pc, agent} ->
        Persistence.broadcast(data.session_id, "model_switched", %{
          provider: prov,
          model: model
        })

        keep(%{data | session: session, agent: agent, provider_config: pc}, [
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
    cancel_pending_steers(data.session_id)

    case data.execution_mode do
      :query_loop ->
        if data.query_loop_task, do: Task.shutdown(data.query_loop_task, :brutal_kill)
        close_open_tool_uses(data.session_id)
        Persistence.set_status(data.session_id, "idle")
        advance(%{data | query_loop_task: nil})

      :graph ->
        if data.stream_ref,
          do: SessionStream.cancel_stream(data.stream_ref, data.session.provider)

        close_open_tool_uses(data.session_id)
        Persistence.set_status(data.session_id, "idle")

        # Bump epoch so surviving I/O task results from this turn are dropped.
        new_epoch = new_epoch()

        # Reset engine, then re-park it at :receive (same maneuver as boot) so
        # the session is immediately ready for the next prompt.
        new_data =
          step_engine(
            %{
              data
              | stream_ref: nil,
                epoch: new_epoch,
                engine_state: reset_engine_state(data),
                engine_node: data.graph.start,
                pending_tool_count: 0,
                pending_approvals: MapSet.new(),
                approval_decisions: %{},
                tool_tasks: %{},
                executed_tool_ids: MapSet.new()
            },
            start_queued?: false
          )

        advance(new_data)
    end
  end

  def handle_event(:cast, {:approve_tool, id}, _state, data),
    do: collect_approval(data, id, :approved)

  def handle_event(:cast, {:deny_tool, id}, _state, data),
    do: collect_approval(data, id, :denied)

  def handle_event(:info, {:node_request, :start_stream, req}, _state, data),
    do: advance(IOHandler.handle_start_stream(req, data))

  def handle_event(:info, {:node_request, :dispatch_tools, c, o}, _state, data),
    do: advance(IOHandler.handle_dispatch_tools(c, o, data))

  def handle_event(:info, {:node_request, :request_approvals, ids}, _state, data),
    do: advance(%{data | pending_approvals: MapSet.new(ids), approval_decisions: %{}})

  def handle_event(:info, {:node_request, :start_auditor, p}, _state, data),
    do: advance(IOHandler.handle_start_auditor(p, data))

  def handle_event(
        :info,
        {:provider_chunk, stream_ref, event},
        _state,
        %{stream_ref: stream_ref} = data
      ),
      do: advance(IOHandler.handle_provider_chunk(event, data))

  def handle_event(:info, {:provider_chunk, _stream_ref, _event}, _state, data),
    do: keep(data)

  def handle_event(:info, {:provider_chunk, _event}, _state, %{stream_ref: %{tag: _}} = data),
    do: keep(data)

  def handle_event(:info, {:provider_chunk, event}, _state, data),
    do: advance(IOHandler.handle_provider_chunk(event, data))

  def handle_event(:info, {:provider_done, stream_ref}, _state, %{stream_ref: stream_ref} = data),
    do: advance(IOHandler.handle_provider_done(data))

  def handle_event(:info, {:provider_done, _stream_ref}, _state, data),
    do: keep(data)

  def handle_event(:info, :provider_done, _state, %{stream_ref: %{tag: _}} = data),
    do: keep(data)

  def handle_event(:info, :provider_done, _state, %{stream_ref: nil} = data),
    do: keep(data)

  def handle_event(:info, :provider_done, _state, data),
    do: advance(IOHandler.handle_provider_done(data))

  def handle_event(
        :info,
        {:provider_error, stream_ref, {:stream_violation, _} = r},
        _state,
        %{stream_ref: stream_ref} = data
      ),
      do: advance(IOHandler.handle_stream_violation(r, data))

  def handle_event(
        :info,
        {:provider_error, stream_ref, r},
        _state,
        %{stream_ref: stream_ref} = data
      ),
      do: advance(IOHandler.handle_provider_error(r, data))

  def handle_event(:info, {:provider_error, _stream_ref, _reason}, _state, data),
    do: keep(data)

  def handle_event(:info, {:provider_error, _reason}, _state, %{stream_ref: %{tag: _}} = data),
    do: keep(data)

  def handle_event(:info, {:provider_error, _reason}, _state, %{stream_ref: nil} = data),
    do: keep(data)

  # Stream-guard violations roll back to the last checkpoint when one exists
  # and resume from the restored engine node; without a checkpoint they fall
  # through to regular provider-error handling.
  def handle_event(:info, {:provider_error, {:stream_violation, _} = r}, _state, data),
    do: advance(IOHandler.handle_stream_violation(r, data))

  def handle_event(:info, {:provider_error, r}, _state, data),
    do: advance(IOHandler.handle_provider_error(r, data))

  # Epoch-fenced tool results — drop if epoch does not match current incarnation.
  def handle_event(:info, {:tool_result, epoch, id, res, err}, _state, %{epoch: epoch} = data),
    do: advance(IOHandler.handle_tool_result(id, res, err, data))

  def handle_event(:info, {:tool_result, _stale_epoch, _id, _res, _err}, _state, data),
    do: keep(data)

  # Legacy unfenced tool results (from global TaskSupervisor path) — still handled.
  def handle_event(:info, {:tool_result, id, res, err}, _state, data) when is_binary(id),
    do: advance(IOHandler.handle_tool_result(id, res, err, data))

  def handle_event(:info, {:auditor_completed, _}, _state, data) do
    new_ctx = Map.put(data.engine_ctx, :auditor_completed, true)
    advance(step_engine(%{data | engine_ctx: new_ctx}))
  end

  # QueryLoop events
  def handle_event(:info, {:query_event, event}, _state, %{execution_mode: :query_loop} = data),
    do: advance(IOHandler.handle_query_loop_event(event, data))

  # QueryLoop Task completion (success)
  def handle_event(
        :info,
        {ref, {:ok, _reason, _final_state}},
        _state,
        %{query_loop_task: %Task{ref: task_ref}} = data
      )
      when ref == task_ref do
    Process.demonitor(ref, [:flush])
    Persistence.set_status(data.session_id, "idle")
    advance(maybe_start_next_prompt(%{data | query_loop_task: nil}))
  end

  # QueryLoop Task DOWN
  def handle_event(
        :info,
        {:DOWN, ref, :process, _pid, reason},
        _state,
        %{query_loop_task: %Task{ref: task_ref}} = data
      )
      when ref == task_ref do
    Logger.warning("query_loop_task_down", session_id: data.session_id, reason: inspect(reason))
    Persistence.set_status(data.session_id, "idle")
    advance(maybe_start_next_prompt(%{data | query_loop_task: nil}))
  end

  # Tool task monitor — abnormal exit without having sent a tool_result.
  def handle_event(:info, {:DOWN, ref, :process, _pid, reason}, _state, data)
      when is_reference(ref) do
    case Map.fetch(data.tool_tasks, ref) do
      {:ok, tool_use_id} ->
        advance(IOHandler.handle_tool_task_down(ref, tool_use_id, reason, data))

      :error ->
        keep(data)
    end
  end

  def handle_event(:timeout, :inactivity, _state, data) do
    Logger.info("session_inactivity_timeout", session_id: data.session_id)
    Persistence.update_session_status(data.session_id, "idle")
    {:stop, :normal}
  end

  def handle_event(:info, _msg, _state, data), do: keep(data)

  @impl :gen_statem
  def terminate(reason, _state, data) do
    Logger.info("session_worker_terminated",
      session_id: data.session_id,
      reason: inspect(reason)
    )

    if Code.ensure_loaded?(Synapsis.Tool.Teammate) and
         function_exported?(Synapsis.Tool.Teammate, :delete_all, 1) do
      Synapsis.Tool.Teammate.delete_all(data.session_id)
    end

    :ok
  end

  # --- State machine helpers ---

  @doc """
  Derive the machine state from the data. Called after every event so the
  state can never disagree with the engine/I-O fields it summarizes.
  """
  def derive_state(%__MODULE__{} = d) do
    cond do
      d.execution_mode == :query_loop and d.query_loop_task != nil -> :query_loop
      MapSet.size(d.pending_approvals) > 0 -> :awaiting_approval
      d.stream_ref != nil -> :generating
      d.pending_tool_count > 0 -> :executing_tools
      engine_ready?(d) -> :idle
      true -> :busy
    end
  end

  defp advance(%__MODULE__{} = data, actions \\ []) do
    {:next_state, derive_state(data), data, actions ++ [timeout_action()]}
  end

  defp keep(%__MODULE__{} = _data, actions \\ []) do
    {:keep_state_and_data, actions ++ [timeout_action()]}
  end

  defp timeout_action, do: {:timeout, @timeout, :inactivity}

  defp external_status(:idle), do: :waiting
  defp external_status(_state), do: :running

  # --- Engine helpers ---

  @doc false
  def step_engine(%__MODULE__{} = state) do
    step_engine(state, start_queued?: true)
  end

  defp step_engine(%__MODULE__{} = state, opts) do
    start_queued? = Keyword.get(opts, :start_queued?, true)

    if start_queued? and Keyword.get(opts, :drain_before?, true) and
         can_start_queued_prompt?(state) do
      start_queued_graph_prompt(state)
    else
      new_state =
        case Engine.run_until_wait(
               state.graph,
               state.engine_node,
               state.engine_state,
               state.engine_ctx
             ) do
          {:waiting, node, new_workflow_state} ->
            %{state | engine_node: node, engine_state: new_workflow_state}

          {:done, _new_workflow_state} ->
            # Turn boundary: graph reached :end. Snapshot the whole turn to Concord
            # fire-and-forget (ADR-006 B1) — never blocks the worker — then reset to
            # start for the next turn.
            Synapsis.Session.Snapshot.snapshot_async(state.session_id)
            %{state | engine_node: state.graph.start, engine_state: reset_engine_state(state)}

          {:error, reason, new_workflow_state} ->
            Logger.warning("engine_error", session_id: state.session_id, reason: inspect(reason))
            Persistence.update_session_status(state.session_id, "error")
            Persistence.broadcast(state.session_id, "error", %{message: "Agent engine error"})
            Persistence.broadcast(state.session_id, "session_status", %{status: "error"})
            %{state | engine_state: new_workflow_state}
        end

      if start_queued? do
        maybe_start_next_prompt(new_state)
      else
        new_state
      end
    end
  end

  @doc "True when the engine is parked at :receive waiting for user input."
  def engine_ready?(%__MODULE__{engine_node: node, engine_state: es}) do
    node == :receive and Map.get(es, :awaiting_input, false)
  end

  # --- Private helpers ---

  defp new_epoch, do: System.monotonic_time()

  defp reset_engine_state(state) do
    CodingLoop.initial_state(%{
      session_id: state.session_id,
      provider_config: state.provider_config,
      agent_config: state.agent
    })
  end

  defp recover_pending_inputs(session_id) do
    case PendingInputStore.recover_inflight(session_id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("pending_input_recovery_failed",
          session_id: session_id,
          reason: inspect(reason)
        )
    end
  end

  defp start_graph_turn(state, content, image_parts, opts \\ []) do
    case persist_user_message(state, content, image_parts) do
      :ok ->
        new_engine_ctx =
          state.engine_ctx
          |> Map.put(:user_input, content)
          |> Map.put(:image_parts, image_parts)

        new_state =
          step_engine(
            %{
              state
              | engine_ctx: new_engine_ctx,
                executed_tool_ids: MapSet.new()
            },
            start_queued?: Keyword.get(opts, :start_queued?, true),
            drain_before?: false
          )

        {:ok, new_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_query_loop_turn(state, content, image_parts) do
    case persist_user_message(state, content, image_parts) do
      :ok -> {:ok, start_query_loop(content, state)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp queue_prompt(state, content, image_parts) do
    state.session_id
    |> PendingInputStore.append_prompt(content, image_parts)
    |> broadcast_queued_input(state.session_id)
  end

  defp queue_steer(state, content) do
    state.session_id
    |> PendingInputStore.append_steer(content)
    |> broadcast_queued_input(state.session_id)
  end

  defp broadcast_queued_input({:ok, input}, session_id) do
    Persistence.broadcast(session_id, "input_queued", %{
      id: input.id,
      kind: input.kind,
      content: input.content
    })

    {:ok, input}
  end

  defp broadcast_queued_input({:error, _reason} = error, _session_id), do: error

  defp reply_queue_result({:ok, _input}, from, data),
    do: advance(data, [{:reply, from, :ok}])

  defp reply_queue_result({:error, reason}, from, data),
    do: keep(data, [{:reply, from, {:error, reason}}])

  defp cancel_pending_steers(session_id) do
    case PendingInputStore.cancel_steers(session_id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("pending_steer_cancel_failed",
          session_id: session_id,
          reason: inspect(reason)
        )
    end
  end

  defp maybe_start_next_prompt(%{execution_mode: :graph} = state) do
    if can_start_queued_prompt?(state) do
      start_queued_graph_prompt(state)
    else
      state
    end
  end

  defp maybe_start_next_prompt(%{execution_mode: :query_loop, query_loop_task: nil} = state) do
    start_queued_query_loop_prompt(state)
  end

  defp maybe_start_next_prompt(state), do: state

  defp can_start_queued_prompt?(state) do
    engine_ready?(state) and state.stream_ref == nil and state.pending_tool_count == 0 and
      MapSet.size(state.pending_approvals) == 0
  end

  defp start_queued_graph_prompt(state) do
    case PendingInputStore.take_next_prompt(state.session_id) do
      {:ok, input} ->
        start_queued_prompt(state, input, fn ->
          start_graph_turn(state, input.content, input.image_parts, start_queued?: false)
        end)

      :empty ->
        state

      {:error, reason} ->
        Logger.warning("queued_prompt_take_failed",
          session_id: state.session_id,
          reason: inspect(reason)
        )

        state
    end
  end

  defp start_queued_query_loop_prompt(state) do
    case PendingInputStore.take_next_prompt(state.session_id) do
      {:ok, input} ->
        start_queued_prompt(state, input, fn ->
          start_query_loop_turn(state, input.content, input.image_parts)
        end)

      :empty ->
        state

      {:error, reason} ->
        Logger.warning("queued_prompt_take_failed",
          session_id: state.session_id,
          reason: inspect(reason)
        )

        state
    end
  end

  defp start_queued_prompt(state, input, starter) do
    case starter.() do
      {:ok, new_state} ->
        if mark_pending_input_consumed(state.session_id, input) == :ok do
          broadcast_started_input(state.session_id, input)
        end

        new_state

      {:error, reason} ->
        recover_queued_prompt_start_failure(state.session_id, input, reason)
        state
    end
  rescue
    exception ->
      recover_queued_prompt_start_failure(state.session_id, input, exception)
      state
  catch
    kind, reason ->
      recover_queued_prompt_start_failure(state.session_id, input, {kind, reason})
      state
  end

  defp recover_queued_prompt_start_failure(session_id, input, reason) do
    case PendingInputStore.recover_inflight(session_id) do
      :ok ->
        :ok

      {:error, recover_reason} ->
        Logger.warning("queued_prompt_requeue_failed",
          session_id: session_id,
          input_id: input.id,
          reason: inspect(recover_reason)
        )
    end

    Logger.warning("queued_prompt_start_failed",
      session_id: session_id,
      input_id: input.id,
      reason: inspect(reason)
    )
  end

  defp broadcast_started_input(session_id, input) do
    Persistence.broadcast(session_id, "input_started", %{
      id: input.id,
      kind: input.kind,
      content: input.content
    })
  end

  defp mark_pending_input_consumed(session_id, input) do
    case PendingInputStore.mark_consumed(session_id, input.id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("pending_input_consume_failed",
          session_id: session_id,
          input_id: input.id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp persist_user_message(state, content, image_parts) do
    case Persistence.persist_user_message(state.session_id, content, image_parts) do
      :ok ->
        Persistence.set_status(state.session_id, "streaming")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_approval(data, tool_use_id, decision) do
    decisions = Map.put(data.approval_decisions, tool_use_id, decision)
    data = %{data | approval_decisions: decisions}

    if MapSet.size(data.pending_approvals) > 0 and
         Enum.all?(data.pending_approvals, &Map.has_key?(decisions, &1)) do
      new_ctx = Map.put(data.engine_ctx, :approval_decisions, decisions)

      new_data =
        step_engine(%{
          data
          | engine_ctx: new_ctx,
            pending_approvals: MapSet.new(),
            approval_decisions: %{}
        })

      advance(new_data)
    else
      advance(data)
    end
  end

  defp close_open_tool_uses(session_id) do
    _ = ResponseFlusher.ensure_tool_results(session_id, "Tool use cancelled by user.", true)
    :ok
  end

  # --- QueryLoop helpers (unchanged) ---

  defp start_query_loop(content, state) do
    messages = build_query_loop_messages(state.session_id)
    messages = messages ++ [%{role: "user", content: content}]

    loop_state = %Synapsis.Agent.QueryLoop.State{
      messages: messages,
      max_turns: Map.get(state.agent || %{}, :max_turns, 50)
    }

    agent_config =
      (state.agent || %{})
      |> Map.merge(%{
        agent_type: agent_type_from_name((state.agent || %{})[:name]),
        agent_id: state.session && state.session.agent,
        name: (state.agent || %{})[:name]
      })

    loop_ctx = %Synapsis.Agent.QueryLoop.Context{
      session_id: state.session_id,
      system_prompt: :dynamic,
      tools: resolve_agent_tools(state.agent),
      model: (state.agent || %{})[:model] || "claude-sonnet-4-5-20250514",
      provider_config: state.provider_config,
      subscriber: self(),
      project_path: state.project_path,
      working_dir: state.project_path,
      agent_config: agent_config
    }

    task = Task.async(fn -> Synapsis.Agent.QueryLoop.run(loop_state, loop_ctx) end)
    %{state | query_loop_task: task}
  end

  defp build_query_loop_messages(session_id) do
    Synapsis.Message.list_by_session(session_id)
    |> Enum.map(fn msg ->
      %{role: msg.role, content: format_message_content(msg)}
    end)
  rescue
    _ -> []
  end

  defp format_message_content(msg) do
    case msg.parts do
      parts when is_list(parts) and length(parts) > 0 ->
        parts
        |> Enum.map(fn
          %Synapsis.Part.Text{content: t} ->
            %{type: "text", text: t || ""}

          %Synapsis.Part.ToolUse{tool: name, tool_use_id: id, input: input} ->
            %{type: "tool_use", id: id, name: name, input: input || %{}}

          %Synapsis.Part.ToolResult{tool_use_id: id, content: c, is_error: e} ->
            %{type: "tool_result", tool_use_id: id, content: c || "", is_error: e || false}

          _ ->
            nil
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        ""
    end
  end

  defp resolve_agent_tools(agent) do
    case (agent || %{})[:tools] do
      names when is_list(names) and names != [] ->
        Synapsis.Tool.Registry.list_for_query_loop(names: names)

      _ ->
        Synapsis.Tool.Registry.list_for_query_loop()
    end
  end

  defp agent_type_from_name("assistant"), do: :conversational
  defp agent_type_from_name("plan"), do: :planning
  defp agent_type_from_name(_), do: :coding
end
