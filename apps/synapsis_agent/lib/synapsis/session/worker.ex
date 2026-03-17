defmodule Synapsis.Session.Worker do
  @moduledoc """
  Thin GenServer wrapper around graph-driven execution via Runtime.Runner.

  Responsibilities:
  - Holds session_id, runner_pid, and configuration
  - Translates external API calls into Runner.resume/2 ctx updates
  - Handles async I/O: stream chunks, tool results, approval collection
  - Manages inactivity timeout
  """
  use GenServer
  require Logger

  alias Synapsis.{Repo, Session, Message, ContextWindow}
  alias Synapsis.Session.Stream, as: SessionStream
  alias Synapsis.Session.WorkspaceManager
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
    # Stream accumulator fields
    pending_text: "",
    pending_tool_use: nil,
    pending_tool_input: "",
    pending_reasoning: "",
    tool_uses: [],
    # Tool tracking
    pending_tool_count: 0,
    # Approval tracking
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

  def approve_tool(session_id, tool_use_id),
    do: GenServer.cast(via(session_id), {:approve_tool, tool_use_id})

  def deny_tool(session_id, tool_use_id),
    do: GenServer.cast(via(session_id), {:deny_tool, tool_use_id})

  def switch_agent(session_id, agent_name),
    do: GenServer.call(via(session_id), {:switch_agent, agent_name})

  def switch_model(session_id, provider_name, model),
    do: GenServer.call(via(session_id), {:switch_model, provider_name, model})

  def switch_mode(session_id, mode_name),
    do: GenServer.call(via(session_id), {:switch_mode, mode_name})

  def get_status(session_id), do: GenServer.call(via(session_id), :get_status)

  defp via(session_id), do: {:via, Registry, {Synapsis.Session.Registry, session_id}}

  # --- Init ---

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    case Repo.get(Session, session_id) do
      nil ->
        {:stop, {:error, :session_not_found}}

      session ->
        init_with_session(Repo.preload(session, :project), session_id)
    end
  end

  defp init_with_session(session, session_id) do
    Process.flag(:trap_exit, true)

    agent = resolve_agent(session)
    effective_provider = agent[:provider] || session.provider
    provider_config = resolve_provider_config(effective_provider)
    worktree_path = setup_worktree(session, session_id)

    {:ok, graph} = CodingLoop.build()

    initial_state =
      CodingLoop.initial_state(%{
        session_id: session_id,
        provider_config: provider_config,
        agent_config: agent,
        worktree_path: worktree_path
      })

    # ctx must be JSON-serializable (no PIDs or structs) since Runner checkpoints it.
    # Nodes look up the Worker via Registry using session_id from workflow_state.
    ctx = %{
      provider: effective_provider,
      model: agent[:model] || session.model,
      project_path: session.project.path,
      project_id: to_string(session.project_id)
    }

    {:ok, runner_pid} =
      Runner.start_link(
        graph: graph,
        state: initial_state,
        ctx: ctx,
        run_id: session_id
      )

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
    update_session_status(state.session_id, "streaming")
    broadcast(state.session_id, "session_status", %{status: "streaming"})

    case Runner.resume(state.runner_pid, %{user_input: content, image_parts: image_parts}) do
      :ok -> {:reply, :ok, state, @inactivity_timeout}
      {:error, reason} -> {:reply, {:error, reason}, state, @inactivity_timeout}
    end
  end

  def handle_call(:retry, _from, state) do
    import Ecto.Query, only: [from: 2]

    has_messages =
      Repo.exists?(from(m in Message, where: m.session_id == ^state.session_id))

    if has_messages do
      update_session_status(state.session_id, "streaming")
      broadcast(state.session_id, "session_status", %{status: "streaming"})

      case Runner.resume(state.runner_pid, %{retry: true}) do
        :ok -> {:reply, :ok, state, @inactivity_timeout}
        {:error, reason} -> {:reply, {:error, reason}, state, @inactivity_timeout}
      end
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
    agent = Synapsis.Agent.Resolver.resolve(agent_name, state.session.config)
    agent = ensure_agent_model(agent, state.session)

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
    provider_config = resolve_provider_config(provider_name)
    agent = Map.put(state.agent, :model, model)
    broadcast(state.session_id, "model_switched", %{provider: provider_name, model: model})

    {:reply, :ok, %{state | session: session, agent: agent, provider_config: provider_config},
     @inactivity_timeout}
  end

  def handle_call({:switch_mode, mode_name}, _from, state) do
    case apply_mode(mode_name, state) do
      {:ok, new_state} -> {:reply, :ok, new_state, @inactivity_timeout}
      {:error, reason} -> {:reply, {:error, reason}, state, @inactivity_timeout}
    end
  end

  # --- handle_cast ---

  @impl true
  def handle_cast(:cancel, state) do
    if state.stream_ref do
      SessionStream.cancel_stream(state.stream_ref, state.session.provider)
    end

    update_session_status(state.session_id, "idle")
    broadcast(state.session_id, "session_status", %{status: "idle"})
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

  # --- handle_info: Node requests ---

  @impl true
  def handle_info({:node_request, :start_stream, request}, state) do
    provider = state.agent[:provider] || state.session.provider

    case SessionStream.start_stream(request, state.provider_config, provider) do
      {:ok, ref} ->
        new_state = %{
          state
          | stream_ref: ref,
            pending_text: "",
            pending_tool_use: nil,
            pending_tool_input: "",
            pending_reasoning: "",
            tool_uses: []
        }

        {:noreply, new_state}

      {:error, reason} ->
        Runner.resume(state.runner_pid, %{stream_error: reason})
        {:noreply, state}
    end
  end

  def handle_info({:node_request, :dispatch_tools, classified, dispatch_opts}, state) do
    tool_count = length(classified)
    new_hashes = ToolDispatcher.dispatch_all(classified, self(), state.session_id, dispatch_opts)
    {:noreply, %{state | pending_tool_count: tool_count, tool_call_hashes: new_hashes}}
  end

  def handle_info({:node_request, :request_approvals, tool_ids}, state) do
    {:noreply, %{state | pending_approvals: MapSet.new(tool_ids), approval_decisions: %{}}}
  end

  def handle_info({:node_request, :start_auditor, params}, state) do
    start_auditor_async(params, state)
    {:noreply, state}
  end

  # --- handle_info: Stream events ---

  def handle_info({:provider_chunk, event}, state) do
    acc = extract_acc(state)
    {broadcasts, new_acc} = StreamAccumulator.accumulate(event, acc)

    for {event_name, payload} <- broadcasts do
      broadcast(state.session_id, event_name, payload)
    end

    {:noreply, merge_acc(state, new_acc)}
  end

  def handle_info(:provider_done, state) do
    acc = extract_acc(state)
    Runner.resume(state.runner_pid, %{stream_acc: acc})
    {:noreply, %{state | stream_ref: nil}}
  end

  def handle_info({:provider_error, reason}, state) do
    Logger.warning("provider_error", session_id: state.session_id, reason: inspect(reason))
    Runner.resume(state.runner_pid, %{stream_error: reason})
    {:noreply, %{state | stream_ref: nil}}
  end

  # --- handle_info: Tool results ---

  def handle_info({:tool_result, tool_use_id, result, is_error}, state) do
    ResponseFlusher.flush_tool_result(state.session_id, tool_use_id, result, is_error)

    broadcast(state.session_id, "tool_result", %{
      tool_use_id: tool_use_id,
      content: result,
      is_error: is_error
    })

    remaining = state.pending_tool_count - 1
    state = %{state | pending_tool_count: remaining}

    if remaining <= 0 do
      Runner.resume(state.runner_pid, %{tools_completed: true})
    end

    {:noreply, state}
  end

  # --- handle_info: Auditor ---

  def handle_info({:auditor_completed, _result}, state) do
    Runner.resume(state.runner_pid, %{auditor_completed: true})
    {:noreply, state}
  end

  # --- handle_info: Process lifecycle ---

  def handle_info({:EXIT, pid, reason}, %{runner_pid: pid} = state) do
    Logger.warning("runner_exited", session_id: state.session_id, reason: inspect(reason))
    update_session_status(state.session_id, "error")
    broadcast(state.session_id, "error", %{message: "Agent runner crashed"})
    broadcast(state.session_id, "session_status", %{status: "error"})
    {:noreply, %{state | runner_pid: nil}, @inactivity_timeout}
  end

  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state, @inactivity_timeout}

  def handle_info({:EXIT, _pid, reason}, state) do
    Logger.warning("linked_process_exited", session_id: state.session_id, reason: inspect(reason))
    {:noreply, state, @inactivity_timeout}
  end

  def handle_info(:timeout, state) do
    Logger.info("session_inactivity_timeout", session_id: state.session_id)
    update_session_status(state.session_id, "idle")
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, :normal}, state),
    do: {:noreply, state, @inactivity_timeout}

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state),
    do: {:noreply, state, @inactivity_timeout}

  def handle_info(_msg, state), do: {:noreply, state, @inactivity_timeout}

  @impl true
  def terminate(reason, state) do
    Logger.info("session_worker_terminated",
      session_id: state.session_id,
      reason: inspect(reason)
    )

    if state.worktree_path do
      WorkspaceManager.teardown(state.session.project.path, state.session_id)
    end

    :ok
  end

  # --- Private helpers ---

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
    text_part = %Synapsis.Part.Text{content: content}
    parts = [text_part | image_parts]
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

  defp broadcast(session_id, event, payload) do
    Phoenix.PubSub.broadcast(Synapsis.PubSub, "session:#{session_id}", {event, payload})
  end

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

  defp resolve_agent(session) do
    agent = Synapsis.Agent.Resolver.resolve(session.agent, session.config)
    ensure_agent_model(agent, session)
  end

  defp ensure_agent_model(agent, session) do
    cond do
      not is_nil(agent[:model]) ->
        agent

      not is_nil(session.model) ->
        Map.put(agent, :model, session.model)

      true ->
        tier = agent[:model_tier] || :default
        provider = agent[:provider] || session.provider
        Map.put(agent, :model, Synapsis.Providers.model_for_tier(provider, tier))
    end
  end

  defp resolve_provider_config(provider_name) do
    case Synapsis.Provider.Registry.get(provider_name) do
      {:ok, config} ->
        config

      {:error, _} ->
        case Synapsis.Providers.get_by_name(provider_name) do
          {:ok, provider} ->
            %{
              api_key: provider.api_key_encrypted,
              base_url: provider.base_url,
              type: provider.type
            }

          {:error, _} ->
            auth = Synapsis.Config.load_auth()
            api_key = get_in(auth, [provider_name, "apiKey"]) || env_key(provider_name)

            %{
              api_key: api_key,
              base_url: Synapsis.Providers.default_base_url(provider_name),
              type: provider_name
            }
        end
    end
  end

  defp env_key(provider_name) do
    case Synapsis.Providers.env_var_name(provider_name) do
      nil -> nil
      var -> System.get_env(var)
    end
  end

  @valid_modes ~w(bypass_permissions ask_before_edits edit_automatically plan_mode)
  @mode_configs %{
    "bypass_permissions" => %{
      agent: "build",
      permission: %{
        mode: :autonomous,
        allow_write: :allow,
        allow_execute: :allow,
        allow_destructive: :allow
      }
    },
    "ask_before_edits" => %{
      agent: "build",
      permission: %{
        mode: :interactive,
        allow_write: :ask,
        allow_execute: :ask,
        allow_destructive: :ask
      }
    },
    "edit_automatically" => %{
      agent: "build",
      permission: %{
        mode: :autonomous,
        allow_write: :allow,
        allow_execute: :allow,
        allow_destructive: :ask
      }
    },
    "plan_mode" => %{
      agent: "plan",
      permission: %{
        mode: :interactive,
        allow_write: :deny,
        allow_execute: :deny,
        allow_destructive: :deny
      }
    }
  }

  defp apply_mode(mode_name, state) when mode_name in @valid_modes do
    config = @mode_configs[mode_name]
    agent = Synapsis.Agent.Resolver.resolve(config.agent, state.session.config)
    agent = ensure_agent_model(agent, state.session)
    {:ok, _} = state.session |> Session.changeset(%{agent: config.agent}) |> Repo.update()

    case Synapsis.Tool.Permission.update_config(state.session_id, config.permission) do
      {:ok, _} ->
        session = %{state.session | agent: config.agent}
        broadcast(state.session_id, "mode_switched", %{mode: mode_name, agent: config.agent})
        {:ok, %{state | agent: agent, session: session}}

      {:error, _} ->
        {:error, :permission_update_failed}
    end
  end

  defp apply_mode(_mode_name, _state), do: {:error, :invalid_mode}

  defp start_auditor_async(params, state) do
    worker_pid = self()

    Task.Supervisor.async_nolink(Synapsis.Tool.TaskSupervisor, fn ->
      auditor_request =
        Synapsis.Session.AuditorTask.prepare_escalation(
          params.session_id,
          params.monitor,
          params.agent_config
        )

      auditor_provider = auditor_request.config.provider || state.session.provider

      provider_config =
        case Synapsis.Provider.Registry.get(auditor_provider) do
          {:ok, cfg} -> cfg
          {:error, _} -> state.provider_config
        end

      provider_type = provider_config[:type] || provider_config["type"] || "anthropic"

      request = %{
        model:
          auditor_request.config.model || provider_config[:default_model] ||
            Synapsis.Providers.model_for_tier(auditor_provider, :fast),
        max_tokens: auditor_request.config.max_tokens || 1024,
        system: auditor_request.system_prompt,
        messages: [%{role: "user", content: auditor_request.user_message}]
      }

      config = Map.put(provider_config, :type, provider_type)

      case Synapsis.Provider.Adapter.complete(request, config) do
        {:ok, response_text} ->
          Synapsis.Session.AuditorTask.record_analysis(
            params.session_id,
            response_text,
            trigger: to_string(params.decision),
            auditor_model: request.model
          )

        {:error, err} ->
          Logger.warning("auditor_invocation_failed",
            session_id: params.session_id,
            reason: inspect(err)
          )
      end

      send(worker_pid, {:auditor_completed, :ok})
    end)
  end
end
