defmodule Synapsis.Agent.GlobalAgent do
  @moduledoc """
  Singleton conversational agent for the Assistant system.

  Runs `Graphs.ConversationalLoop` — the persistent receive → compact →
  build_prompt → reason → act → respond → (loop) cycle. Uses the same
  `Runtime.Runner` and `Session.Worker` I/O infrastructure as `Session.Worker`
  but boots the conversational graph instead of the coding graph.

  One `GlobalAgent` exists per system. It is intended to be started under
  `SynapsisAgent.Application` as a permanent child, linked to a singleton
  "global" session in the database.

  ## API

      # Start for a given session
      GlobalAgent.start_link(session_id: "global-session-uuid")

      # Send a user message
      GlobalAgent.send_message(session_id, "What PRs need review?")

      # Cancel current stream
      GlobalAgent.cancel(session_id)

  ## Design

  Re-uses `Session.Worker.Boot` with `graph_module: ConversationalLoop` so the
  streaming, tool dispatch, and I/O event handling are identical to the coding
  loop. The only difference is the graph topology and tool set.
  """

  use GenServer

  alias Synapsis.Agent.Runtime.Runner
  alias Synapsis.Session.Worker.{Boot, IOHandler, Persistence}
  alias Synapsis.Session.Stream, as: SessionStream

  require Logger

  @timeout :timer.minutes(30)

  defstruct [
    :session_id,
    :session,
    :agent,
    :provider_config,
    :runner_pid,
    :stream_ref,
    :debug_handler_id,
    stream_acc: Synapsis.Agent.StreamAccumulator.new(),
    pending_tool_count: 0,
    pending_approvals: MapSet.new(),
    approval_decisions: %{}
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
  def cancel(session_id) do
    GenServer.cast(via(session_id), :cancel)
  end

  @spec get_status(String.t()) :: atom()
  def get_status(session_id) do
    GenServer.call(via(session_id), :get_status)
  end

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    case Boot.load_and_boot(session_id,
           graph_module: Synapsis.Agent.Graphs.ConversationalLoop
         ) do
      {session, agent, provider_config, runner_pid, _worktree, _project_path} ->
        state = %__MODULE__{
          session_id: session_id,
          session: session,
          agent: agent,
          provider_config: provider_config,
          runner_pid: runner_pid
        }

        Logger.info("global_agent_started", session_id: session_id)
        {:ok, state, @timeout}

      {:stop, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:send_message, content, image_parts}, _from, state) do
    Persistence.persist_user_message(state.session_id, content, image_parts)
    Persistence.set_status(state.session_id, "streaming")

    case Runner.resume(state.runner_pid, %{user_input: content, image_parts: image_parts}) do
      :ok -> {:reply, :ok, state, @timeout}
      {:error, reason} -> {:reply, {:error, reason}, state, @timeout}
    end
  end

  def handle_call(:get_status, _from, state) do
    status =
      if state.runner_pid do
        try do
          Runner.snapshot(state.runner_pid)[:status] || :unknown
        catch
          :exit, _ -> :unknown
        end
      else
        :unknown
      end

    {:reply, status, state, @timeout}
  end

  @impl true
  def handle_cast(:cancel, state) do
    if state.stream_ref do
      provider = state.agent[:provider] || state.session.provider
      SessionStream.cancel_stream(state.stream_ref, provider)
    end

    if state.runner_pid do
      try do
        GenServer.stop(state.runner_pid, :normal)
      catch
        :exit, _ -> :ok
      end
    end

    Persistence.set_status(state.session_id, "idle")
    {:noreply, %{state | stream_ref: nil, runner_pid: nil}, @timeout}
  end

  @impl true
  def handle_info({:node_request, :start_stream, req}, s) do
    IOHandler.handle_start_stream(req, s)
    |> noreply_from_io(s)
  end

  def handle_info({:node_request, :dispatch_tools, c, o}, s) do
    IOHandler.handle_dispatch_tools(c, o, s)
    |> noreply_from_io(s)
  end

  def handle_info({:node_request, :request_approvals, ids}, s) do
    {:noreply, %{s | pending_approvals: MapSet.new(ids), approval_decisions: %{}}}
  end

  def handle_info({:node_request, :start_auditor, p}, s) do
    IOHandler.handle_start_auditor(p, s)
    |> noreply_from_io(s)
  end

  def handle_info({:provider_chunk, event}, s) do
    IOHandler.handle_provider_chunk(event, s)
    |> noreply_from_io(s)
  end

  def handle_info(:provider_done, s) do
    IOHandler.handle_provider_done(s)
    |> noreply_from_io(s)
  end

  def handle_info({:provider_error, r}, s) do
    IOHandler.handle_provider_error(r, s)
    |> noreply_from_io(s)
  end

  def handle_info({:tool_result, id, res, err}, s) do
    IOHandler.handle_tool_result(id, res, err, s)
    |> noreply_from_io(s)
  end

  def handle_info({:EXIT, pid, _reason}, %{runner_pid: pid} = s) do
    Logger.warning("global_agent_runner_exit", session_id: s.session_id)
    Persistence.set_status(s.session_id, "idle")
    {:noreply, %{s | runner_pid: nil}, @timeout}
  end

  def handle_info(:timeout, state) do
    Logger.info("global_agent_idle_timeout", session_id: state.session_id)
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state, @timeout}

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp via(session_id), do: {:via, Registry, {Synapsis.Agent.Registry, {__MODULE__, session_id}}}

  # IOHandler returns `{:noreply, state}` or `{:noreply, state, timeout}`.
  # Normalize to always include the module's timeout.
  defp noreply_from_io({:noreply, new_state}, _old), do: {:noreply, new_state, @timeout}
end
