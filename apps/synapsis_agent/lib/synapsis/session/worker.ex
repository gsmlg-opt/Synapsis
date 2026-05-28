defmodule Synapsis.Session.Worker do
  @moduledoc "Thin GenServer wrapper around graph-driven Runtime.Runner execution."
  use GenServer
  require Logger

  alias Synapsis.Session.Stream, as: SessionStream
  alias Synapsis.Session.Worker.{Boot, Config, IOHandler, Persistence}
  alias Synapsis.Agent.Graphs.CodingLoop
  alias Synapsis.Agent.ResponseFlusher
  alias Synapsis.Agent.Runtime.Runner

  @timeout :timer.minutes(30)
  @runner_ready_timeout 1_000

  defstruct [
    :session_id,
    :session,
    :agent,
    :provider_config,
    :runner_pid,
    :stream_ref,
    :project_path,
    :debug_handler_id,
    stream_acc: Synapsis.Agent.StreamAccumulator.new(),
    pending_tool_count: 0,
    pending_approvals: MapSet.new(),
    approval_decisions: %{},
    execution_mode: :graph,
    query_loop_task: nil,
    tool_tasks: MapSet.new()
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

      {session, agent, pc, runner, project_path} ->
        Logger.info("session_worker_started", session_id: session.id)

        {:ok,
         %__MODULE__{
           session_id: session.id,
           session: session,
           agent: agent,
           provider_config: pc,
           runner_pid: runner,
           project_path: project_path
         }, @timeout}
    end
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
        with {:ok, ready_state} <- prepare_graph_runner_for_message(state),
             :ok <- persist_user_message(ready_state, content, image_parts) do
          resume_reply(ready_state, %{user_input: content, image_parts: image_parts})
        else
          {:error, reason} ->
            {:reply, {:error, reason}, state, @timeout}
        end
    end
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
      if state.runner_pid do
        try do
          Runner.snapshot(state.runner_pid)[:status] || :unknown
        catch
          :exit, _ -> :unknown
        end
      else
        :unknown
      end

    {:reply, s, state, @timeout}
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

        force_stop_runner(state.runner_pid)
        close_open_tool_uses(state.session_id)
        Persistence.set_status(state.session_id, "idle")

        {:noreply, %{state | stream_ref: nil, runner_pid: nil, tool_tasks: MapSet.new()},
         @timeout}
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
    do: {:noreply, %{s | pending_approvals: MapSet.new(ids), approval_decisions: %{}}}

  def handle_info({:node_request, :start_auditor, p}, s), do: IOHandler.handle_start_auditor(p, s)
  def handle_info({:provider_chunk, event}, s), do: IOHandler.handle_provider_chunk(event, s)
  def handle_info(:provider_done, s), do: IOHandler.handle_provider_done(s)
  def handle_info({:provider_error, r}, s), do: IOHandler.handle_provider_error(r, s)

  def handle_info({:tool_result, id, res, err}, s),
    do: IOHandler.handle_tool_result(id, res, err, s)

  def handle_info({:auditor_completed, _}, s) do
    if s.runner_pid, do: Runner.resume(s.runner_pid, %{auditor_completed: true})
    {:noreply, s}
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

  # QueryLoop Task DOWN (crash or shutdown)
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{query_loop_task: %Task{ref: task_ref}} = s
      )
      when ref == task_ref do
    Logger.warning("query_loop_task_down",
      session_id: s.session_id,
      reason: inspect(reason)
    )

    Persistence.set_status(s.session_id, "idle")
    {:noreply, %{s | query_loop_task: nil}, @timeout}
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

  # Tool task crashed — the try/rescue/catch in ToolDispatcher.execute_async should
  # normally prevent this, but as a safety net we handle task crashes here by
  # decrementing the pending tool count so the runner doesn't stay stuck waiting.
  def handle_info({:DOWN, ref, :process, _pid, reason}, s)
      when is_reference(ref) do
    if MapSet.member?(s.tool_tasks, ref) do
      IOHandler.handle_tool_task_down(ref, reason, s)
    else
      {:noreply, s, @timeout}
    end
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

  defp resume_reply(state, ctx) do
    if state.runner_pid do
      case Runner.resume(state.runner_pid, ctx) do
        :ok -> {:reply, :ok, state, @timeout}
        {:error, r} -> {:reply, {:error, r}, state, @timeout}
      end
    else
      {:reply, {:error, :no_runner}, state, @timeout}
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

  defp prepare_graph_runner_for_message(state) do
    case runner_snapshot(state.runner_pid) do
      {:ok, %{status: :waiting, node: :receive}} ->
        {:ok, state}

      {:ok, %{status: :running, node: node}} when node in [:receive, :complete] ->
        await_graph_runner_ready(state)

      {:ok, %{status: status}} when status in [:completed, :failed] ->
        restart_graph_runner(state)

      {:ok, %{status: :waiting, node: node}} ->
        {:error, {:runner_waiting_on, node}}

      {:ok, %{status: status, node: node}} ->
        {:error, {:runner_not_ready, status, node}}

      {:error, :no_runner} ->
        restart_graph_runner(state)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp runner_snapshot(nil), do: {:error, :no_runner}

  defp runner_snapshot(pid) do
    {:ok, Runner.snapshot(pid)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp await_graph_runner_ready(state) do
    case Runner.await(state.runner_pid, @runner_ready_timeout) do
      %{status: :waiting, node: :receive} ->
        {:ok, state}

      %{status: status, node: node} ->
        {:error, {:runner_not_ready, status, node}}

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp restart_graph_runner(state) do
    stop_runner(state.runner_pid)

    case start_graph_runner(state) do
      {:ok, runner_pid} ->
        await_graph_runner_ready(%{
          state
          | runner_pid: runner_pid,
            stream_ref: nil,
            stream_acc: Synapsis.Agent.StreamAccumulator.new(),
            pending_tool_count: 0,
            pending_approvals: MapSet.new(),
            approval_decisions: %{},
            tool_tasks: MapSet.new()
        })

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_graph_runner(state) do
    with {:ok, graph} <- CodingLoop.build() do
      Runner.start_link(
        graph: graph,
        state:
          CodingLoop.initial_state(%{
            session_id: state.session_id,
            provider_config: state.provider_config,
            agent_config: state.agent
          }),
        ctx: graph_ctx(state),
        run_id: state.session_id
      )
    end
  end

  defp graph_ctx(state) do
    agent = state.agent || %{}

    %{
      provider: agent[:provider] || state.session.provider,
      model: agent[:model] || state.session.model,
      project_path: state.project_path,
      agent_id: state.session.agent || agent[:name] || "main"
    }
  end

  defp stop_runner(nil), do: :ok

  defp stop_runner(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp force_stop_runner(nil), do: :ok

  defp force_stop_runner(pid) when is_pid(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    :ok
  end

  defp close_open_tool_uses(session_id) do
    _ = ResponseFlusher.ensure_tool_results(session_id, "Tool use cancelled by user.", true)
    :ok
  end

  # -- QueryLoop helpers --

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

  defp collect_approval(state, tool_use_id, decision) do
    decisions = Map.put(state.approval_decisions, tool_use_id, decision)
    state = %{state | approval_decisions: decisions}

    if state.runner_pid && MapSet.size(state.pending_approvals) > 0 &&
         Enum.all?(state.pending_approvals, &Map.has_key?(decisions, &1)) do
      Runner.resume(state.runner_pid, %{approval_decisions: decisions})
      {:noreply, %{state | pending_approvals: MapSet.new(), approval_decisions: %{}}, @timeout}
    else
      {:noreply, state, @timeout}
    end
  end
end
