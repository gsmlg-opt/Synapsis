defmodule Synapsis.Session.Worker do
  @moduledoc """
  Per-session GenServer. Owns the graph engine and all I/O state.

  The engine (pure functions in `Runtime.Engine`) is stepped inline — no
  separate Runner process, no cross-process resume dance. Long-running I/O
  (LLM streaming, tool execution) is delegated via messages to the Worker's
  mailbox and coordinated by IOHandler.

  ## Epoch fencing

  Every boot assigns a new monotonic epoch. Tasks capture the epoch at spawn
  and stamp every result/chunk message. The Worker drops messages whose epoch
  does not match the current one, so results from a dead incarnation (surviving
  after a `rest_for_one` restart) are silently discarded.
  """
  use GenServer
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

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via(session_id))
  end

  def send_message(session_id, content, image_parts \\ []),
    do: GenServer.call(via(session_id), {:send_message, content, image_parts}, 30_000)

  def cancel(session_id), do: GenServer.cast(via(session_id), :cancel)
  def retry(session_id), do: GenServer.call(via(session_id), :retry, 30_000)
  def approve_tool(session_id, id), do: GenServer.cast(via(session_id), {:approve_tool, id})
  def deny_tool(session_id, id), do: GenServer.cast(via(session_id), {:deny_tool, id})
  def switch_agent(session_id, n), do: GenServer.call(via(session_id), {:switch_agent, n}, 10_000)

  def switch_model(session_id, p, m),
    do: GenServer.call(via(session_id), {:switch_model, p, m}, 10_000)

  def switch_mode(session_id, mode),
    do: GenServer.call(via(session_id), {:switch_mode, mode}, 10_000)

  def get_status(session_id), do: GenServer.call(via(session_id), :get_status, 10_000)

  defp via(id), do: {:via, Registry, {Synapsis.Session.Registry, id}}

  @impl true
  def init(opts) do
    case Boot.load_and_boot(Keyword.fetch!(opts, :session_id)) do
      {:stop, reason} ->
        {:stop, reason}

      {session, agent, pc, graph, engine_state, engine_ctx, project_path} ->
        Logger.info("session_worker_started", session_id: session.id)

        state = %__MODULE__{
          session_id: session.id,
          session: session,
          agent: agent,
          provider_config: pc,
          graph: graph,
          engine_node: graph.start,
          engine_state: engine_state,
          engine_ctx: engine_ctx,
          epoch: new_epoch(),
          project_path: project_path
        }

        # Park the engine at :receive after init so the Worker is registered first.
        {:ok, state, {:continue, :init_engine}}
    end
  end

  @impl true
  def handle_continue(:init_engine, state) do
    {:noreply, step_engine(state), @timeout}
  end

  @impl true
  def handle_call({:send_message, content, image_parts}, _from, state) do
    case state.execution_mode do
      :query_loop ->
        case persist_user_message(state, content, image_parts) do
          :ok ->
            new_state = start_query_loop(content, state)
            {:reply, :ok, new_state, @timeout}

          {:error, reason} ->
            {:reply, {:error, reason}, state, @timeout}
        end

      :graph ->
        if engine_ready?(state) do
          case persist_user_message(state, content, image_parts) do
            :ok ->
              new_engine_ctx =
                state.engine_ctx
                |> Map.put(:user_input, content)
                |> Map.put(:image_parts, image_parts)

              # Reset per-turn idempotency guard on each new user message.
              new_state =
                step_engine(%{
                  state
                  | engine_ctx: new_engine_ctx,
                    executed_tool_ids: MapSet.new()
                })

              {:reply, :ok, new_state, @timeout}

            {:error, reason} ->
              {:reply, {:error, reason}, state, @timeout}
          end
        else
          {:reply, {:error, {:engine_not_ready, state.engine_node}}, state, @timeout}
        end
    end
  end

  def handle_call(:retry, _from, state) do
    if Persistence.has_messages?(state.session_id) do
      Persistence.set_status(state.session_id, "streaming")
      new_state = step_engine(state)
      {:reply, :ok, new_state, @timeout}
    else
      {:reply, {:error, :no_messages}, state, @timeout}
    end
  end

  def handle_call(:get_status, _from, state) do
    status =
      cond do
        not engine_ready?(state) -> :running
        true -> :waiting
      end

    {:reply, status, state, @timeout}
  end

  def handle_call({:switch_agent, name}, _from, state) do
    case Config.do_switch_agent(name, state.session) do
      {:ok, agent, session} ->
        Persistence.broadcast(state.session_id, "agent_switched", %{agent: to_string(name)})
        {:reply, :ok, %{state | agent: agent, session: session}, @timeout}

      {:error, reason} ->
        {:reply, {:error, reason}, state, @timeout}
    end
  end

  def handle_call({:switch_model, prov, model}, _from, state) do
    case Config.do_switch_model(prov, model, state) do
      {:ok, session, pc, agent} ->
        Persistence.broadcast(state.session_id, "model_switched", %{provider: prov, model: model})
        {:reply, :ok, %{state | session: session, agent: agent, provider_config: pc}, @timeout}

      {:error, reason} ->
        {:reply, {:error, reason}, state, @timeout}
    end
  end

  def handle_call({:switch_mode, mode}, _from, state) do
    case Config.apply_mode(mode, state) do
      {:ok, s} -> {:reply, :ok, s, @timeout}
      {:error, r} -> {:reply, {:error, r}, state, @timeout}
    end
  end

  @impl true
  def handle_cast(:cancel, state) do
    case state.execution_mode do
      :query_loop ->
        if state.query_loop_task, do: Task.shutdown(state.query_loop_task, :brutal_kill)
        close_open_tool_uses(state.session_id)
        Persistence.set_status(state.session_id, "idle")
        {:noreply, %{state | query_loop_task: nil}, @timeout}

      :graph ->
        if state.stream_ref,
          do: SessionStream.cancel_stream(state.stream_ref, state.session.provider)

        close_open_tool_uses(state.session_id)
        Persistence.set_status(state.session_id, "idle")

        # Bump epoch so surviving I/O task results from this turn are dropped.
        new_epoch = new_epoch()

        # Reset engine back to :receive/idle
        initial = reset_engine_state(state)

        {:noreply,
         %{
           state
           | stream_ref: nil,
             epoch: new_epoch,
             engine_state: initial,
             engine_node: state.graph.start,
             pending_tool_count: 0,
             pending_approvals: MapSet.new(),
             approval_decisions: %{},
             tool_tasks: %{},
             executed_tool_ids: MapSet.new()
         }, @timeout}
    end
  end

  def handle_cast({:approve_tool, id}, state), do: collect_approval(state, id, :approved)
  def handle_cast({:deny_tool, id}, state), do: collect_approval(state, id, :denied)

  @impl true
  def handle_info({:node_request, :start_stream, req}, s),
    do: IOHandler.handle_start_stream(req, s)

  def handle_info({:node_request, :dispatch_tools, c, o}, s),
    do: IOHandler.handle_dispatch_tools(c, o, s)

  def handle_info({:node_request, :request_approvals, ids}, s),
    do: {:noreply, %{s | pending_approvals: MapSet.new(ids), approval_decisions: %{}}, @timeout}

  def handle_info({:node_request, :start_auditor, p}, s), do: IOHandler.handle_start_auditor(p, s)
  def handle_info({:provider_chunk, event}, s), do: IOHandler.handle_provider_chunk(event, s)
  def handle_info(:provider_done, s), do: IOHandler.handle_provider_done(s)
  def handle_info({:provider_error, r}, s), do: IOHandler.handle_provider_error(r, s)

  # Epoch-fenced tool results — drop if epoch does not match current incarnation.
  def handle_info({:tool_result, epoch, id, res, err}, %{epoch: epoch} = s),
    do: IOHandler.handle_tool_result(id, res, err, s)

  def handle_info({:tool_result, _stale_epoch, _id, _res, _err}, s),
    do: {:noreply, s, @timeout}

  # Legacy unfenced tool results (from global TaskSupervisor path) — still handled.
  def handle_info({:tool_result, id, res, err}, s) when is_binary(id),
    do: IOHandler.handle_tool_result(id, res, err, s)

  def handle_info({:auditor_completed, _}, s) do
    new_ctx = Map.put(s.engine_ctx, :auditor_completed, true)
    {:noreply, step_engine(%{s | engine_ctx: new_ctx}), @timeout}
  end

  # QueryLoop events
  def handle_info({:query_event, event}, %{execution_mode: :query_loop} = s),
    do: IOHandler.handle_query_loop_event(event, s)

  # QueryLoop Task completion (success)
  def handle_info(
        {ref, {:ok, _reason, _final_state}},
        %{query_loop_task: %Task{ref: task_ref}} = s
      )
      when ref == task_ref do
    Process.demonitor(ref, [:flush])
    Persistence.set_status(s.session_id, "idle")
    {:noreply, %{s | query_loop_task: nil}, @timeout}
  end

  # QueryLoop Task DOWN
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{query_loop_task: %Task{ref: task_ref}} = s
      )
      when ref == task_ref do
    Logger.warning("query_loop_task_down", session_id: s.session_id, reason: inspect(reason))
    Persistence.set_status(s.session_id, "idle")
    {:noreply, %{s | query_loop_task: nil}, @timeout}
  end

  # Tool task monitor — abnormal exit without having sent a tool_result.
  def handle_info({:DOWN, ref, :process, _pid, reason}, s) when is_reference(ref) do
    case Map.fetch(s.tool_tasks, ref) do
      {:ok, tool_use_id} -> IOHandler.handle_tool_task_down(ref, tool_use_id, reason, s)
      :error -> {:noreply, s, @timeout}
    end
  end

  def handle_info(:timeout, s) do
    Logger.info("session_inactivity_timeout", session_id: s.session_id)
    Persistence.update_session_status(s.session_id, "idle")
    {:stop, :normal, s}
  end

  def handle_info(_msg, s), do: {:noreply, s, @timeout}

  @impl true
  def terminate(reason, state) do
    Logger.info("session_worker_terminated",
      session_id: state.session_id,
      reason: inspect(reason)
    )

    if Code.ensure_loaded?(Synapsis.Tool.Teammate) and
         function_exported?(Synapsis.Tool.Teammate, :delete_all, 1) do
      Synapsis.Tool.Teammate.delete_all(state.session_id)
    end

    :ok
  end

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
        # Graph reached :end — reset to start (next turn).
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

  defp collect_approval(state, tool_use_id, decision) do
    decisions = Map.put(state.approval_decisions, tool_use_id, decision)
    state = %{state | approval_decisions: decisions}

    if MapSet.size(state.pending_approvals) > 0 and
         Enum.all?(state.pending_approvals, &Map.has_key?(decisions, &1)) do
      new_ctx = Map.put(state.engine_ctx, :approval_decisions, decisions)

      new_state =
        step_engine(%{
          state
          | engine_ctx: new_ctx,
            pending_approvals: MapSet.new(),
            approval_decisions: %{}
        })

      {:noreply, new_state, @timeout}
    else
      {:noreply, state, @timeout}
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
