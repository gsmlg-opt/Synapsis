defmodule Synapsis.Agent.GlobalAgent do
  @moduledoc """
  Singleton conversational agent for the Assistant system.

  Runs `Graphs.ConversationalLoop` — the persistent receive → compact →
  build_prompt → reason → act → respond → (loop) cycle. Uses the same
  `Runtime.Engine` and `Session.Worker` I/O infrastructure as `Session.Worker`
  but boots the conversational graph instead of the coding graph.
  """

  use GenServer

  alias Synapsis.Agent.{AgentRegistry, Memory.EventStore}
  alias Synapsis.Agent.Runtime.Engine
  alias Synapsis.Agent.Graphs.ConversationalLoop
  alias Synapsis.Session.Worker.{Boot, IOHandler, Persistence}
  alias Synapsis.Session.Stream, as: SessionStream
  alias Synapsis.Session.Worker

  require Logger

  @timeout :timer.minutes(30)

  defstruct [
    :session_id,
    :session,
    :agent,
    :provider_config,
    :graph,
    :engine_node,
    :engine_state,
    :engine_ctx,
    :epoch,
    :stream_ref,
    :debug_handler_id,
    stream_acc: Synapsis.Agent.StreamAccumulator.new(),
    pending_tool_count: 0,
    pending_approvals: MapSet.new(),
    approval_decisions: %{},
    tool_tasks: MapSet.new()
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via(session_id))
  end

  @spec send_message(String.t(), String.t(), list()) :: :ok | {:error, term()}
  def send_message(session_id, content, image_parts \\ []) do
    GenServer.call(via(session_id), {:send_message, content, image_parts}, @timeout)
  end

  @spec cancel(String.t()) :: :ok
  def cancel(session_id), do: GenServer.cast(via(session_id), :cancel)

  @spec get_status(String.t()) :: atom()
  def get_status(session_id), do: GenServer.call(via(session_id), :get_status)

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    case Boot.load_and_boot(session_id, graph_module: ConversationalLoop) do
      {session, agent, provider_config, graph, engine_state, engine_ctx, _project_path} ->
        state = %__MODULE__{
          session_id: session_id,
          session: session,
          agent: agent,
          provider_config: provider_config,
          graph: graph,
          engine_node: graph.start,
          engine_state: engine_state,
          engine_ctx: engine_ctx,
          epoch: System.monotonic_time()
        }

        Logger.info("global_agent_started", session_id: session_id)
        {:ok, state, {:continue, :init_engine}}

      {:stop, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:init_engine, state) do
    {:noreply, step_engine(state), @timeout}
  end

  @impl true
  def handle_call({:send_message, content, image_parts}, _from, state) do
    Persistence.persist_user_message(state.session_id, content, image_parts)
    Persistence.set_status(state.session_id, "streaming")

    new_ctx =
      state.engine_ctx
      |> Map.put(:user_input, content)
      |> Map.put(:image_parts, image_parts)

    {:reply, :ok, step_engine(%{state | engine_ctx: new_ctx}), @timeout}
  end

  def handle_call(:get_status, _from, state) do
    status = if Worker.engine_ready?(state), do: :waiting, else: :running
    {:reply, status, state, @timeout}
  end

  @impl true
  def handle_cast(:cancel, state) do
    if state.stream_ref do
      provider = state.agent[:provider] || state.session.provider
      SessionStream.cancel_stream(state.stream_ref, provider)
    end

    Persistence.set_status(state.session_id, "idle")

    initial =
      ConversationalLoop.initial_state(%{
        session_id: state.session_id,
        provider_config: state.provider_config,
        agent_config: state.agent
      })

    {:noreply,
     %{
       state
       | stream_ref: nil,
         epoch: System.monotonic_time(),
         engine_state: initial,
         engine_node: state.graph.start,
         pending_tool_count: 0,
         tool_tasks: MapSet.new()
     }, @timeout}
  end

  @impl true
  def handle_info({:node_request, :start_stream, req}, s),
    do: IOHandler.handle_start_stream(req, s)

  def handle_info({:node_request, :dispatch_tools, c, o}, s),
    do: IOHandler.handle_dispatch_tools(c, o, s)

  def handle_info({:node_request, :request_approvals, ids}, s),
    do: {:noreply, %{s | pending_approvals: MapSet.new(ids), approval_decisions: %{}}, @timeout}

  def handle_info({:node_request, :start_auditor, p}, s),
    do: IOHandler.handle_start_auditor(p, s)

  def handle_info({:provider_chunk, event}, s), do: IOHandler.handle_provider_chunk(event, s)
  def handle_info(:provider_done, s), do: IOHandler.handle_provider_done(s)
  def handle_info({:provider_error, r}, s), do: IOHandler.handle_provider_error(r, s)

  def handle_info({:tool_result, epoch, id, res, err}, %{epoch: epoch} = s),
    do: IOHandler.handle_tool_result(id, res, err, s)

  def handle_info({:tool_result, _stale, _id, _res, _err}, s), do: {:noreply, s, @timeout}

  def handle_info({:tool_result, id, res, err}, s) when is_binary(id),
    do: IOHandler.handle_tool_result(id, res, err, s)

  def handle_info({:auditor_completed, _}, s) do
    new_ctx = Map.put(s.engine_ctx, :auditor_completed, true)
    {:noreply, step_engine(%{s | engine_ctx: new_ctx}), @timeout}
  end

  def handle_info({:coding_session_completed, _ref, child_session_id}, state) do
    AgentRegistry.update_status(child_session_id, :complete)
    summary = fetch_session_summary(child_session_id)

    EventStore.append(%{
      event_type: :code_agent_completed,
      agent_id: state.session.agent || "main",
      work_id: child_session_id,
      payload: %{
        parent_session_id: state.session_id,
        child_session_id: child_session_id,
        summary: summary
      }
    })

    Phoenix.PubSub.broadcast(
      Synapsis.PubSub,
      "session:#{state.session_id}",
      {"code_agent_event",
       %{sub_session_id: child_session_id, event: "done", payload: %{summary: summary}}}
    )

    Logger.info("code_agent_completed",
      parent_session_id: state.session_id,
      child_session_id: child_session_id
    )

    {:noreply, state, @timeout}
  end

  def handle_info({:coding_session_failed, _ref, child_session_id}, state) do
    AgentRegistry.update_status(child_session_id, :failed)

    Phoenix.PubSub.broadcast(
      Synapsis.PubSub,
      "session:#{state.session_id}",
      {"code_agent_event", %{sub_session_id: child_session_id, event: "error", payload: %{}}}
    )

    {:noreply, state, @timeout}
  end

  def handle_info({:coding_session_timeout, _ref, child_session_id}, state) do
    AgentRegistry.update_status(child_session_id, :failed)
    {:noreply, state, @timeout}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, s) when is_reference(ref) do
    if MapSet.member?(s.tool_tasks, ref) do
      IOHandler.handle_tool_task_down(ref, reason, s)
    else
      {:noreply, s, @timeout}
    end
  end

  def handle_info(:timeout, state) do
    Logger.info("global_agent_idle_timeout", session_id: state.session_id)
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state, @timeout}

  # --- Engine helpers ---

  defp step_engine(%__MODULE__{} = state) do
    case Engine.run_until_wait(
           state.graph,
           state.engine_node,
           state.engine_state,
           state.engine_ctx
         ) do
      {:waiting, node, new_workflow_state} ->
        %{state | engine_node: node, engine_state: new_workflow_state}

      {:done, _new_workflow_state} ->
        initial =
          ConversationalLoop.initial_state(%{
            session_id: state.session_id,
            provider_config: state.provider_config,
            agent_config: state.agent
          })

        %{state | engine_node: state.graph.start, engine_state: initial}

      {:error, reason, new_workflow_state} ->
        Logger.warning("global_agent_engine_error",
          session_id: state.session_id,
          reason: inspect(reason)
        )

        Persistence.update_session_status(state.session_id, "error")
        Persistence.broadcast(state.session_id, "error", %{message: "Agent engine error"})
        %{state | engine_state: new_workflow_state}
    end
  end

  defp via(session_id), do: {:via, Registry, {Synapsis.Agent.Registry, {__MODULE__, session_id}}}

  defp fetch_session_summary(session_id) do
    try do
      messages = Synapsis.Sessions.get_messages(session_id, limit: 5)

      messages
      |> Enum.filter(&(&1.role == "assistant"))
      |> List.last()
      |> case do
        nil -> nil
        msg -> String.slice(to_string(msg.content), 0, 500)
      end
    rescue
      _ -> nil
    end
  end
end
