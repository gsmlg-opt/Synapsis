defmodule Synapsis.Session.Worker do
  @moduledoc """
  Thin GenServer wrapper around graph-driven execution via Runtime.Runner.
  Translates external API calls into Runner.resume/2 ctx updates and
  handles async I/O: stream chunks, tool results, approval collection.
  """
  use GenServer
  require Logger

  alias Synapsis.{Repo, Session, Message, ContextWindow}
  alias Synapsis.Session.Stream, as: SessionStream
  alias Synapsis.Session.WorkspaceManager
  alias Synapsis.Session.Worker.{Auditor, Config}
  alias Synapsis.Agent.{StreamAccumulator, ResponseFlusher, ToolDispatcher}
  alias Synapsis.Agent.Runtime.Runner
  alias Synapsis.Agent.Graphs.CodingLoop

  @inactivity_timeout :timer.minutes(30)

  defstruct [
    :session_id,
    :session,
    :agent,
    :provider_config,
    :runner_pid,
    :stream_ref,
    worktree_path: nil,
    pending_text: "",
    pending_tool_use: nil,
    pending_tool_input: "",
    pending_reasoning: "",
    tool_uses: [],
    pending_tool_count: 0,
    pending_approvals: MapSet.new(),
    approval_decisions: %{},
    tool_call_hashes: MapSet.new()
  ]

  # --- Public API ---

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
  def switch_agent(session_id, name), do: GenServer.call(via(session_id), {:switch_agent, name})

  def switch_model(session_id, provider, model),
    do: GenServer.call(via(session_id), {:switch_model, provider, model})

  def switch_mode(session_id, mode), do: GenServer.call(via(session_id), {:switch_mode, mode})
  def get_status(session_id), do: GenServer.call(via(session_id), :get_status)

  defp via(id), do: {:via, Registry, {Synapsis.Session.Registry, id}}

  # --- Init ---

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    case Repo.get(Session, session_id) do
      nil -> {:stop, {:error, :session_not_found}}
      session -> boot(Repo.preload(session, :project), session_id)
    end
  end

  defp boot(session, session_id) do
    Process.flag(:trap_exit, true)

    agent = Config.resolve_agent(session)
    provider = agent[:provider] || session.provider
    provider_config = Config.resolve_provider_config(provider)
    worktree_path = setup_worktree(session, session_id)

    {:ok, graph} = CodingLoop.build()

    initial_state =
      CodingLoop.initial_state(%{
        session_id: session_id,
        provider_config: provider_config,
        agent_config: agent,
        worktree_path: worktree_path
      })

    ctx = %{
      provider: provider,
      model: agent[:model] || session.model,
      project_path: session.project.path,
      project_id: to_string(session.project_id)
    }

    {:ok, runner_pid} =
      Runner.start_link(graph: graph, state: initial_state, ctx: ctx, run_id: session_id)

    state = %__MODULE__{
      session_id: session_id,
      session: session,
      agent: agent,
      provider_config: provider_config,
      runner_pid: runner_pid,
      worktree_path: worktree_path
    }

    Synapsis.Memory.Writer.subscribe_session(session_id)
    Logger.info("session_worker_started", session_id: session_id)
    {:ok, state, @inactivity_timeout}
  end

  # --- handle_call ---

  @impl true
  def handle_call({:send_message, content, image_parts}, _from, state) do
    persist_user_message(state.session_id, content, image_parts)
    set_status(state, "streaming")
    reply_with_resume(state, %{user_input: content, image_parts: image_parts})
  end

  def handle_call(:retry, _from, state) do
    import Ecto.Query, only: [from: 2]

    if Repo.exists?(from(m in Message, where: m.session_id == ^state.session_id)) do
      set_status(state, "streaming")
      reply_with_resume(state, %{retry: true})
    else
      {:reply, {:error, :no_messages}, state, @inactivity_timeout}
    end
  end

  def handle_call(:get_status, _from, state) do
    status =
      case Runner.snapshot(state.runner_pid) do
        %{status: s} -> s
        _ -> :unknown
      end

    {:reply, status, state, @inactivity_timeout}
  end

  def handle_call({:switch_agent, agent_name}, _from, state) do
    agent = Config.resolve_agent(%{state.session | agent: to_string(agent_name)})

    {:ok, _} =
      state.session |> Session.changeset(%{agent: to_string(agent_name)}) |> Repo.update()

    session = %{state.session | agent: to_string(agent_name)}
    broadcast(state.session_id, "agent_switched", %{agent: to_string(agent_name)})
    {:reply, :ok, %{state | agent: agent, session: session}, @inactivity_timeout}
  end

  def handle_call({:switch_model, provider_name, model}, _from, state) do
    {:ok, _} =
      state.session
      |> Session.changeset(%{provider: provider_name, model: model})
      |> Repo.update()

    session = %{state.session | provider: provider_name, model: model}
    provider_config = Config.resolve_provider_config(provider_name)
    broadcast(state.session_id, "model_switched", %{provider: provider_name, model: model})

    {:reply, :ok,
     %{
       state
       | session: session,
         agent: Map.put(state.agent, :model, model),
         provider_config: provider_config
     }, @inactivity_timeout}
  end

  def handle_call({:switch_mode, mode_name}, _from, state) do
    case Config.apply_mode(mode_name, state) do
      {:ok, new_state} -> {:reply, :ok, new_state, @inactivity_timeout}
      {:error, reason} -> {:reply, {:error, reason}, state, @inactivity_timeout}
    end
  end

  # --- handle_cast ---

  @impl true
  def handle_cast(:cancel, state) do
    if state.stream_ref, do: SessionStream.cancel_stream(state.stream_ref, state.session.provider)
    set_status(state, "idle")
    {:noreply, %{state | stream_ref: nil}, @inactivity_timeout}
  end

  def handle_cast({:approve_tool, tool_use_id}, state) do
    decisions = Map.put(state.approval_decisions, tool_use_id, :approved)
    maybe_resume_approval(%{state | approval_decisions: decisions})
  end

  def handle_cast({:deny_tool, tool_use_id}, state) do
    decisions = Map.put(state.approval_decisions, tool_use_id, :denied)
    maybe_resume_approval(%{state | approval_decisions: decisions})
  end

  # --- handle_info ---

  @impl true
  def handle_info({:node_request, :start_stream, request}, state) do
    provider = state.agent[:provider] || state.session.provider

    case SessionStream.start_stream(request, state.provider_config, provider) do
      {:ok, ref} ->
        {:noreply,
         %{
           state
           | stream_ref: ref,
             pending_text: "",
             pending_tool_use: nil,
             pending_tool_input: "",
             pending_reasoning: "",
             tool_uses: []
         }}

      {:error, reason} ->
        Runner.resume(state.runner_pid, %{stream_error: reason})
        {:noreply, state}
    end
  end

  def handle_info({:node_request, :dispatch_tools, classified, opts}, state) do
    count = length(classified)
    hashes = ToolDispatcher.dispatch_all(classified, self(), state.session_id, opts)
    {:noreply, %{state | pending_tool_count: count, tool_call_hashes: hashes}}
  end

  def handle_info({:node_request, :request_approvals, tool_ids}, state),
    do: {:noreply, %{state | pending_approvals: MapSet.new(tool_ids), approval_decisions: %{}}}

  def handle_info({:node_request, :start_auditor, params}, state) do
    Auditor.start_async(params, state)
    {:noreply, state}
  end

  def handle_info({:provider_chunk, event}, state) do
    acc = extract_acc(state)
    {broadcasts, new_acc} = StreamAccumulator.accumulate(event, acc)
    for {name, payload} <- broadcasts, do: broadcast(state.session_id, name, payload)
    {:noreply, merge_acc(state, new_acc)}
  end

  def handle_info(:provider_done, state) do
    Runner.resume(state.runner_pid, %{stream_acc: extract_acc(state)})
    {:noreply, %{state | stream_ref: nil}}
  end

  def handle_info({:provider_error, reason}, state) do
    Logger.warning("provider_error", session_id: state.session_id, reason: inspect(reason))
    Runner.resume(state.runner_pid, %{stream_error: reason})
    {:noreply, %{state | stream_ref: nil}}
  end

  def handle_info({:tool_result, tool_use_id, result, is_error}, state) do
    ResponseFlusher.flush_tool_result(state.session_id, tool_use_id, result, is_error)

    broadcast(state.session_id, "tool_result", %{
      tool_use_id: tool_use_id,
      content: result,
      is_error: is_error
    })

    remaining = state.pending_tool_count - 1
    if remaining <= 0, do: Runner.resume(state.runner_pid, %{tools_completed: true})
    {:noreply, %{state | pending_tool_count: remaining}}
  end

  def handle_info({:auditor_completed, _}, state) do
    Runner.resume(state.runner_pid, %{auditor_completed: true})
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, %{runner_pid: pid} = state) do
    Logger.warning("runner_exited", session_id: state.session_id, reason: inspect(reason))
    update_session_status(state.session_id, "error")
    broadcast(state.session_id, "error", %{message: "Agent runner crashed"})
    broadcast(state.session_id, "session_status", %{status: "error"})
    {:noreply, %{state | runner_pid: nil}, @inactivity_timeout}
  end

  def handle_info({:EXIT, _, :normal}, state), do: {:noreply, state, @inactivity_timeout}

  def handle_info({:EXIT, _, reason}, state) do
    Logger.warning("linked_process_exited", session_id: state.session_id, reason: inspect(reason))
    {:noreply, state, @inactivity_timeout}
  end

  def handle_info(:timeout, state) do
    Logger.info("session_inactivity_timeout", session_id: state.session_id)
    update_session_status(state.session_id, "idle")
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _, :process, _, _}, state), do: {:noreply, state, @inactivity_timeout}
  def handle_info(_msg, state), do: {:noreply, state, @inactivity_timeout}

  @impl true
  def terminate(reason, state) do
    Logger.info("session_worker_terminated",
      session_id: state.session_id,
      reason: inspect(reason)
    )

    if state.worktree_path,
      do: WorkspaceManager.teardown(state.session.project.path, state.session_id)

    :ok
  end

  # --- Private helpers ---

  defp reply_with_resume(state, ctx_updates) do
    case Runner.resume(state.runner_pid, ctx_updates) do
      :ok -> {:reply, :ok, state, @inactivity_timeout}
      {:error, reason} -> {:reply, {:error, reason}, state, @inactivity_timeout}
    end
  end

  defp set_status(state, status) do
    update_session_status(state.session_id, status)
    broadcast(state.session_id, "session_status", %{status: status})
  end

  defp extract_acc(state) do
    %{
      pending_text: state.pending_text,
      pending_tool_use: state.pending_tool_use,
      pending_tool_input: state.pending_tool_input,
      pending_reasoning: state.pending_reasoning,
      tool_uses: state.tool_uses
    }
  end

  defp merge_acc(state, acc) do
    %{
      state
      | pending_text: acc.pending_text,
        pending_tool_use: acc.pending_tool_use,
        pending_tool_input: acc.pending_tool_input,
        pending_reasoning: acc.pending_reasoning,
        tool_uses: acc.tool_uses
    }
  end

  defp maybe_resume_approval(state) do
    all_decided =
      MapSet.size(state.pending_approvals) > 0 and
        Enum.all?(state.pending_approvals, &Map.has_key?(state.approval_decisions, &1))

    if all_decided do
      Runner.resume(state.runner_pid, %{approval_decisions: state.approval_decisions})

      {:noreply, %{state | pending_approvals: MapSet.new(), approval_decisions: %{}},
       @inactivity_timeout}
    else
      {:noreply, state, @inactivity_timeout}
    end
  end

  defp persist_user_message(session_id, content, image_parts) do
    parts = [%Synapsis.Part.Text{content: content} | image_parts]
    token_count = ContextWindow.estimate_tokens(content) + length(image_parts) * 1000

    case %Message{}
         |> Message.changeset(%{
           session_id: session_id,
           role: "user",
           parts: parts,
           token_count: token_count
         })
         |> Repo.insert() do
      {:ok, _} ->
        :ok

      {:error, cs} ->
        Logger.warning("message_insert_failed",
          session_id: session_id,
          errors: inspect(cs.errors)
        )
    end
  end

  defp broadcast(session_id, event, payload),
    do: Phoenix.PubSub.broadcast(Synapsis.PubSub, "session:#{session_id}", {event, payload})

  defp update_session_status(session_id, status) do
    case Repo.get(Session, session_id) do
      nil -> :ok
      session -> session |> Session.status_changeset(status) |> Repo.update()
    end
  rescue
    _ -> :ok
  end

  defp setup_worktree(session, session_id) do
    if Synapsis.Git.is_repo?(session.project.path) do
      case WorkspaceManager.setup(session.project.path, session_id) do
        {:ok, path} -> path
        {:error, _} -> nil
      end
    end
  end
end
