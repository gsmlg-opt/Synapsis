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
  for policy: a new user prompt is accepted only in `:idle` — the busy-reject
  policy lives in exactly one clause (see `handle_event` for `:send_message`).

  ## Epoch fencing

  Every boot assigns a new monotonic epoch. Tasks capture the epoch at spawn
  and stamp every result/chunk message. The Worker drops messages whose epoch
  does not match the current one, so results from a dead incarnation (surviving
  after a `rest_for_one` restart) are silently discarded.
  """
  @behaviour :gen_statem
  require Logger

  alias Synapsis.Session.Stream, as: SessionStream
  alias Synapsis.Session.Worker.{Boot, Config, IOHandler, Persistence}
  alias Synapsis.Agent.Graphs.CodingLoop
  alias Synapsis.Agent.ResponseFlusher
  alias Synapsis.Agent.Runtime.Engine

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

  def cancel(session_id), do: :gen_statem.cast(via(session_id), :cancel)
  def retry(session_id), do: :gen_statem.call(via(session_id), :retry, 30_000)
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
      {:query_loop, _} ->
        case persist_user_message(data, content, image_parts) do
          :ok ->
            advance(start_query_loop(content, data), [{:reply, from, :ok}])

          {:error, reason} ->
            keep(data, [{:reply, from, {:error, reason}}])
        end

      {:graph, :idle} ->
        case persist_user_message(data, content, image_parts) do
          :ok ->
            new_engine_ctx =
              data.engine_ctx
              |> Map.put(:user_input, content)
              |> Map.put(:image_parts, image_parts)

            # Reset per-turn idempotency guard on each new user message.
            new_data =
              step_engine(%{
                data
                | engine_ctx: new_engine_ctx,
                  executed_tool_ids: MapSet.new()
              })

            advance(new_data, [{:reply, from, :ok}])

          {:error, reason} ->
            keep(data, [{:reply, from, {:error, reason}}])
        end

      {:graph, _busy} ->
        # The only place the mid-turn-prompt policy lives (harness ADR-0006):
        # a session that is not :idle rejects new prompts; abort first.
        keep(data, [{:reply, from, {:error, {:engine_not_ready, data.engine_node}}}])
    end
  end

  def handle_event({:call, from}, :retry, _state, data) do
    if Persistence.has_messages?(data.session_id) do
      Persistence.set_status(data.session_id, "streaming")
      advance(step_engine(data), [{:reply, from, :ok}])
    else
      keep(data, [{:reply, from, {:error, :no_messages}}])
    end
  end

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
          step_engine(%{
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
          })

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

  def handle_event(:info, {:provider_chunk, event}, _state, data),
    do: advance(IOHandler.handle_provider_chunk(event, data))

  def handle_event(:info, :provider_done, _state, data),
    do: advance(IOHandler.handle_provider_done(data))

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
    advance(%{data | query_loop_task: nil})
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
    advance(%{data | query_loop_task: nil})
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
