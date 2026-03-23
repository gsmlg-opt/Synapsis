defmodule Synapsis.Session.Worker do
  @moduledoc "Thin GenServer wrapper around graph-driven Runtime.Runner execution."
  use GenServer
  require Logger

  alias Synapsis.Session.Stream, as: SessionStream
  alias Synapsis.Session.WorkspaceManager
  alias Synapsis.Session.Worker.{Boot, Config, IOHandler, Persistence}
  alias Synapsis.Agent.Runtime.Runner

  @timeout :timer.minutes(30)

  defstruct [
    :session_id,
    :session,
    :agent,
    :provider_config,
    :runner_pid,
    :stream_ref,
    :project_path,
    worktree_path: nil,
    stream_acc: Synapsis.Agent.StreamAccumulator.new(),
    pending_tool_count: 0,
    pending_approvals: MapSet.new(),
    approval_decisions: %{}
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
  def switch_agent(session_id, n), do: GenServer.call(via(session_id), {:switch_agent, n})
  def switch_model(session_id, p, m), do: GenServer.call(via(session_id), {:switch_model, p, m})
  def switch_mode(session_id, mode), do: GenServer.call(via(session_id), {:switch_mode, mode})
  def get_status(session_id), do: GenServer.call(via(session_id), :get_status)

  defp via(id), do: {:via, Registry, {Synapsis.Session.Registry, id}}

  @impl true
  def init(opts) do
    case Boot.load_and_boot(Keyword.fetch!(opts, :session_id)) do
      {:stop, reason} ->
        {:stop, reason}

      {session, agent, pc, runner, wt, project_path} ->
        Logger.info("session_worker_started", session_id: session.id)

        {:ok,
         %__MODULE__{
           session_id: session.id,
           session: session,
           agent: agent,
           provider_config: pc,
           runner_pid: runner,
           worktree_path: wt,
           project_path: project_path
         }, @timeout}
    end
  end

  @impl true
  def handle_call({:send_message, content, image_parts}, _from, state) do
    Persistence.persist_user_message(state.session_id, content, image_parts)
    Persistence.set_status(state.session_id, "streaming")
    resume_reply(state, %{user_input: content, image_parts: image_parts})
  end

  def handle_call(:retry, _from, state) do
    if Persistence.has_messages?(state.session_id) do
      Persistence.set_status(state.session_id, "streaming")
      resume_reply(state, %{retry: true})
    else
      {:reply, {:error, :no_messages}, state, @timeout}
    end
  end

  def handle_call(:get_status, _from, state) do
    s =
      if state.runner_pid,
        do: Runner.snapshot(state.runner_pid)[:status] || :unknown,
        else: :unknown

    {:reply, s, state, @timeout}
  end

  def handle_call({:switch_agent, name}, _from, state) do
    {agent, session} = Config.do_switch_agent(name, state.session)
    Persistence.broadcast(state.session_id, "agent_switched", %{agent: to_string(name)})
    {:reply, :ok, %{state | agent: agent, session: session}, @timeout}
  end

  def handle_call({:switch_model, prov, model}, _from, state) do
    {session, pc, agent} = Config.do_switch_model(prov, model, state)
    Persistence.broadcast(state.session_id, "model_switched", %{provider: prov, model: model})
    {:reply, :ok, %{state | session: session, agent: agent, provider_config: pc}, @timeout}
  end

  def handle_call({:switch_mode, mode}, _from, state) do
    case Config.apply_mode(mode, state) do
      {:ok, s} -> {:reply, :ok, s, @timeout}
      {:error, r} -> {:reply, {:error, r}, state, @timeout}
    end
  end

  @impl true
  def handle_cast(:cancel, state) do
    if state.stream_ref, do: SessionStream.cancel_stream(state.stream_ref, state.session.provider)

    if state.runner_pid && Process.alive?(state.runner_pid),
      do: GenServer.stop(state.runner_pid, :normal)

    Persistence.set_status(state.session_id, "idle")
    {:noreply, %{state | stream_ref: nil, runner_pid: nil}, @timeout}
  end

  def handle_cast({:approve_tool, id}, state), do: collect_approval(state, id, :approved)
  def handle_cast({:deny_tool, id}, state), do: collect_approval(state, id, :denied)

  @impl true
  def handle_info({:node_request, :start_stream, req}, s),
    do: IOHandler.handle_start_stream(req, s)

  def handle_info({:node_request, :dispatch_tools, c, o}, s),
    do: IOHandler.handle_dispatch_tools(c, o, s)

  def handle_info({:node_request, :request_approvals, ids}, s),
    do: {:noreply, %{s | pending_approvals: MapSet.new(ids), approval_decisions: %{}}}

  def handle_info({:node_request, :start_auditor, p}, s), do: IOHandler.handle_start_auditor(p, s)
  def handle_info({:provider_chunk, event}, s), do: IOHandler.handle_provider_chunk(event, s)
  def handle_info(:provider_done, s), do: IOHandler.handle_provider_done(s)
  def handle_info({:provider_error, r}, s), do: IOHandler.handle_provider_error(r, s)

  def handle_info({:tool_result, id, res, err}, s),
    do: IOHandler.handle_tool_result(id, res, err, s)

  def handle_info({:auditor_completed, _}, s) do
    Runner.resume(s.runner_pid, %{auditor_completed: true})
    {:noreply, s}
  end

  def handle_info({:EXIT, pid, reason}, %{runner_pid: pid} = s),
    do: IOHandler.handle_runner_exit(reason, s)

  def handle_info({:EXIT, _, :normal}, s), do: {:noreply, s, @timeout}

  def handle_info({:EXIT, _, r}, s) do
    Logger.warning("linked_process_exited", session_id: s.session_id, reason: inspect(r))
    {:noreply, s, @timeout}
  end

  def handle_info(:timeout, s) do
    Logger.info("session_inactivity_timeout", session_id: s.session_id)
    Persistence.update_session_status(s.session_id, "idle")
    {:stop, :normal, s}
  end

  def handle_info({:DOWN, _, :process, _, _}, s), do: {:noreply, s, @timeout}
  def handle_info(_msg, s), do: {:noreply, s, @timeout}

  @impl true
  def terminate(reason, state) do
    Logger.info("session_worker_terminated",
      session_id: state.session_id,
      reason: inspect(reason)
    )

    if state.worktree_path,
      do: WorkspaceManager.teardown(state.project_path, state.session_id)

    :ok
  end

  defp resume_reply(state, ctx) do
    case Runner.resume(state.runner_pid, ctx) do
      :ok -> {:reply, :ok, state, @timeout}
      {:error, r} -> {:reply, {:error, r}, state, @timeout}
    end
  end

  defp collect_approval(state, tool_use_id, decision) do
    decisions = Map.put(state.approval_decisions, tool_use_id, decision)
    state = %{state | approval_decisions: decisions}

    if MapSet.size(state.pending_approvals) > 0 and
         Enum.all?(state.pending_approvals, &Map.has_key?(decisions, &1)) do
      Runner.resume(state.runner_pid, %{approval_decisions: decisions})
      {:noreply, %{state | pending_approvals: MapSet.new(), approval_decisions: %{}}, @timeout}
    else
      {:noreply, state, @timeout}
    end
  end
end
