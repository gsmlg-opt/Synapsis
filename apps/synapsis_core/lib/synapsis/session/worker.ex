defmodule Synapsis.Session.Worker do
  @moduledoc """
  GenServer managing a single session's lifecycle.
  State machine: idle → streaming → tool_executing → idle.
  Transient state in process, persistent state in DB.
  """
  use GenServer
  require Logger

  alias Synapsis.{Repo, Session, Message, ContextWindow}
  alias Synapsis.Session.Stream, as: SessionStream

  @max_tool_iterations 25

  defstruct [
    :session_id,
    :session,
    :agent,
    :provider_config,
    :stream_ref,
    status: :idle,
    pending_text: "",
    pending_tool_use: nil,
    pending_tool_input: "",
    pending_reasoning: "",
    tool_uses: [],
    retry_count: 0,
    tool_call_hashes: MapSet.new(),
    iteration_count: 0
  ]

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via(session_id))
  end

  def send_message(session_id, content, image_parts \\ []) do
    GenServer.call(via(session_id), {:send_message, content, image_parts}, 30_000)
  end

  def cancel(session_id) do
    GenServer.cast(via(session_id), :cancel)
  end

  def retry(session_id) do
    GenServer.call(via(session_id), :retry, 30_000)
  end

  def approve_tool(session_id, tool_use_id) do
    GenServer.cast(via(session_id), {:approve_tool, tool_use_id})
  end

  def deny_tool(session_id, tool_use_id) do
    GenServer.cast(via(session_id), {:deny_tool, tool_use_id})
  end

  def get_status(session_id) do
    GenServer.call(via(session_id), :get_status)
  end

  defp via(session_id) do
    {:via, Registry, {Synapsis.Session.Registry, session_id}}
  end

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    session = Repo.get!(Session, session_id) |> Repo.preload(:project)

    agent = Synapsis.Agent.Resolver.resolve(session.agent, session.config)
    provider_config = resolve_provider_config(session.provider)

    state = %__MODULE__{
      session_id: session_id,
      session: session,
      agent: agent,
      provider_config: provider_config
    }

    Logger.info("session_worker_started", session_id: session_id)
    {:ok, state}
  end

  @impl true
  def handle_call({:send_message, content, image_parts}, _from, %{status: :idle} = state) do
    text_part = %Synapsis.Part.Text{content: content}
    parts = [text_part | image_parts]

    token_count =
      ContextWindow.estimate_tokens(content) + length(image_parts) * 1000

    {:ok, _user_msg} =
      %Message{}
      |> Message.changeset(%{
        session_id: state.session_id,
        role: "user",
        parts: parts,
        token_count: token_count
      })
      |> Repo.insert()

    update_session_status(state.session_id, "streaming")
    broadcast(state.session_id, "session_status", %{status: "streaming"})

    # Check if compaction is needed before streaming
    Synapsis.Session.Compactor.maybe_compact(state.session_id, state.session.model)

    # Load all messages and start streaming
    messages = load_messages(state.session_id)
    request = Synapsis.MessageBuilder.build_request(messages, state.agent, state.session.provider)

    # Reset loop safety counters on new user message
    state = %{state | tool_call_hashes: MapSet.new(), iteration_count: 0}

    case SessionStream.start_stream(request, state.provider_config, state.session.provider) do
      {:ok, ref} ->
        {:reply, :ok,
         %{state | status: :streaming, stream_ref: ref, pending_text: "", tool_uses: []}}

      {:error, reason} ->
        update_session_status(state.session_id, "error")
        broadcast(state.session_id, "error", %{message: inspect(reason)})
        {:reply, {:error, reason}, %{state | status: :error}}
    end
  end

  def handle_call({:send_message, _content, _image_parts}, _from, state) do
    {:reply, {:error, :not_idle}, state}
  end

  def handle_call(:retry, _from, %{status: status} = state) when status in [:error, :idle] do
    messages = load_messages(state.session_id)

    if length(messages) > 0 do
      update_session_status(state.session_id, "streaming")
      broadcast(state.session_id, "session_status", %{status: "streaming"})

      request =
        Synapsis.MessageBuilder.build_request(messages, state.agent, state.session.provider)

      case SessionStream.start_stream(request, state.provider_config, state.session.provider) do
        {:ok, ref} ->
          {:reply, :ok,
           %{state | status: :streaming, stream_ref: ref, pending_text: "", tool_uses: []}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :no_messages}, state}
    end
  end

  def handle_call(:retry, _from, state) do
    {:reply, {:error, :not_idle}, state}
  end

  def handle_call(:get_status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_cast(:cancel, %{status: :streaming, stream_ref: ref} = state) when not is_nil(ref) do
    SessionStream.cancel_stream(ref, state.session.provider)
    flush_pending(state)
    update_session_status(state.session_id, "idle")
    broadcast(state.session_id, "session_status", %{status: "idle"})
    {:noreply, %{state | status: :idle, stream_ref: nil}}
  end

  def handle_cast(:cancel, state) do
    {:noreply, state}
  end

  def handle_cast({:approve_tool, tool_use_id}, %{status: :tool_executing} = state) do
    case find_pending_tool(state.tool_uses, tool_use_id) do
      nil ->
        {:noreply, state}

      tool_use ->
        execute_tool(tool_use, state)
    end
  end

  def handle_cast({:approve_tool, _}, state), do: {:noreply, state}

  def handle_cast({:deny_tool, tool_use_id}, %{status: :tool_executing} = state) do
    result_part = %Synapsis.Part.ToolResult{
      tool_use_id: tool_use_id,
      content: "Tool use denied by user.",
      is_error: true
    }

    {:ok, _msg} =
      %Message{}
      |> Message.changeset(%{
        session_id: state.session_id,
        role: "user",
        parts: [result_part],
        token_count: 5
      })
      |> Repo.insert()

    broadcast(state.session_id, "tool_result", %{
      tool_use_id: tool_use_id,
      content: "Tool use denied by user.",
      is_error: true
    })

    remaining = reject_tool(state.tool_uses, tool_use_id)
    continue_after_tools(remaining, state)
  end

  def handle_cast({:deny_tool, _}, state), do: {:noreply, state}

  @impl true
  def handle_info({:provider_chunk, event}, %{status: :streaming} = state) do
    state = handle_stream_event(event, state)
    {:noreply, state}
  end

  def handle_info(:provider_done, %{status: :streaming} = state) do
    state = flush_pending(state)

    if Enum.empty?(state.tool_uses) do
      update_session_status(state.session_id, "idle")
      broadcast(state.session_id, "done", %{})
      broadcast(state.session_id, "session_status", %{status: "idle"})
      {:noreply, %{state | status: :idle, stream_ref: nil}}
    else
      update_session_status(state.session_id, "tool_executing")
      broadcast(state.session_id, "session_status", %{status: "tool_executing"})
      process_tool_uses(%{state | status: :tool_executing, stream_ref: nil})
    end
  end

  def handle_info({:provider_error, reason}, %{status: :streaming} = state) do
    Logger.warning("provider_error", session_id: state.session_id, reason: reason)
    retry_count = Map.get(state, :retry_count, 0)

    if retry_count < 3 and retriable_error?(reason) do
      Logger.info("provider_retry", session_id: state.session_id, attempt: retry_count + 1)
      delay = :timer.seconds(trunc(:math.pow(2, retry_count)))
      Process.send_after(self(), :retry_stream, delay)
      {:noreply, %{state | status: :error, stream_ref: nil, retry_count: retry_count + 1}}
    else
      flush_pending(state)
      update_session_status(state.session_id, "error")
      broadcast(state.session_id, "error", %{message: reason})
      broadcast(state.session_id, "session_status", %{status: "error"})
      {:noreply, %{state | status: :error, stream_ref: nil}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{stream_ref: ref} = state) do
    if reason != :normal do
      Logger.warning("stream_process_down", session_id: state.session_id, reason: inspect(reason))
      flush_pending(state)
      update_session_status(state.session_id, "error")
      broadcast(state.session_id, "error", %{message: "Stream process terminated"})
      broadcast(state.session_id, "session_status", %{status: "error"})
      {:noreply, %{state | status: :error, stream_ref: nil}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:tool_result, tool_use_id, result, is_error}, state) do
    result_part = %Synapsis.Part.ToolResult{
      tool_use_id: tool_use_id,
      content: result,
      is_error: is_error
    }

    {:ok, _msg} =
      %Message{}
      |> Message.changeset(%{
        session_id: state.session_id,
        role: "user",
        parts: [result_part],
        token_count: ContextWindow.estimate_tokens(result)
      })
      |> Repo.insert()

    broadcast(state.session_id, "tool_result", %{
      tool_use_id: tool_use_id,
      content: result,
      is_error: is_error
    })

    remaining = reject_tool(state.tool_uses, tool_use_id)
    continue_after_tools(remaining, state)
  end

  def handle_info(:retry_stream, %{status: :error} = state) do
    messages = load_messages(state.session_id)
    request = Synapsis.MessageBuilder.build_request(messages, state.agent, state.session.provider)

    case SessionStream.start_stream(request, state.provider_config, state.session.provider) do
      {:ok, ref} ->
        update_session_status(state.session_id, "streaming")
        broadcast(state.session_id, "session_status", %{status: "streaming"})

        {:noreply,
         %{state | status: :streaming, stream_ref: ref, pending_text: "", tool_uses: []}}

      {:error, _reason} ->
        update_session_status(state.session_id, "error")
        broadcast(state.session_id, "session_status", %{status: "error"})
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    Logger.info("session_worker_terminated",
      session_id: state.session_id,
      reason: inspect(reason)
    )

    :ok
  end

  # Stream event handlers
  defp handle_stream_event({:text_delta, text}, state) do
    broadcast(state.session_id, "text_delta", %{text: text})
    %{state | pending_text: state.pending_text <> text}
  end

  defp handle_stream_event(:text_start, state), do: state

  defp handle_stream_event({:tool_use_start, name, id}, state) do
    broadcast(state.session_id, "tool_use", %{tool: name, tool_use_id: id})
    %{state | pending_tool_use: %{tool: name, tool_use_id: id}, pending_tool_input: ""}
  end

  defp handle_stream_event({:tool_input_delta, json}, state) do
    %{state | pending_tool_input: state.pending_tool_input <> json}
  end

  defp handle_stream_event({:tool_use_complete, name, args}, state) do
    tool_use = %Synapsis.Part.ToolUse{
      tool: name,
      tool_use_id: "tu_#{System.unique_integer([:positive])}",
      input: args,
      status: :pending
    }

    %{state | tool_uses: state.tool_uses ++ [tool_use]}
  end

  defp handle_stream_event(:content_block_stop, state) do
    case state.pending_tool_use do
      nil ->
        state

      %{tool: name, tool_use_id: id} ->
        input =
          case Jason.decode(state.pending_tool_input) do
            {:ok, parsed} -> parsed
            _ -> %{}
          end

        tool_use = %Synapsis.Part.ToolUse{
          tool: name,
          tool_use_id: id,
          input: input,
          status: :pending
        }

        %{
          state
          | pending_tool_use: nil,
            pending_tool_input: "",
            tool_uses: state.tool_uses ++ [tool_use]
        }
    end
  end

  defp handle_stream_event(:reasoning_start, state), do: state

  defp handle_stream_event({:reasoning_delta, text}, state) do
    broadcast(state.session_id, "reasoning", %{text: text})
    %{state | pending_reasoning: state.pending_reasoning <> text}
  end

  defp handle_stream_event(:message_start, state), do: state
  defp handle_stream_event({:message_delta, _delta}, state), do: state
  defp handle_stream_event(:done, state), do: state
  defp handle_stream_event(:ignore, state), do: state

  defp handle_stream_event({:error, error}, state) do
    Logger.warning("stream_error_event", session_id: state.session_id, error: inspect(error))
    state
  end

  defp flush_pending(state) do
    parts = build_assistant_parts(state)

    if parts != [] do
      token_count =
        parts
        |> Enum.map(fn
          %Synapsis.Part.Text{content: c} -> ContextWindow.estimate_tokens(c)
          _ -> 10
        end)
        |> Enum.sum()

      {:ok, _msg} =
        %Message{}
        |> Message.changeset(%{
          session_id: state.session_id,
          role: "assistant",
          parts: parts,
          token_count: token_count
        })
        |> Repo.insert()
    end

    %{
      state
      | pending_text: "",
        pending_reasoning: "",
        pending_tool_use: nil,
        pending_tool_input: ""
    }
  end

  defp build_assistant_parts(state) do
    parts = []

    parts =
      if state.pending_reasoning != "" do
        parts ++ [%Synapsis.Part.Reasoning{content: state.pending_reasoning}]
      else
        parts
      end

    parts =
      if state.pending_text != "" do
        parts ++ [%Synapsis.Part.Text{content: state.pending_text}]
      else
        parts
      end

    parts =
      Enum.reduce(state.tool_uses, parts, fn tu, acc ->
        acc ++ [tu]
      end)

    parts
  end

  defp process_tool_uses(%{tool_uses: []} = state) do
    {:noreply, state}
  end

  defp process_tool_uses(state) do
    # Record tool call hashes for loop detection
    new_hashes =
      Enum.reduce(state.tool_uses, state.tool_call_hashes, fn tu, acc ->
        MapSet.put(acc, :erlang.phash2({tu.tool, tu.input}))
      end)

    state = %{state | tool_call_hashes: new_hashes}

    for tool_use <- state.tool_uses do
      permission = Synapsis.Tool.Permission.check(tool_use.tool, state.session)

      case permission do
        :approved ->
          execute_tool_async(tool_use, state)

        :requires_approval ->
          broadcast(state.session_id, "permission_request", %{
            tool: tool_use.tool,
            tool_use_id: tool_use.tool_use_id,
            input: tool_use.input
          })
      end
    end

    {:noreply, state}
  end

  defp execute_tool(tool_use, state) do
    execute_tool_async(tool_use, state)
    {:noreply, state}
  end

  defp execute_tool_async(tool_use, state) do
    worker_pid = self()
    project_path = state.session.project.path

    # Check for duplicate tool calls within the same turn
    call_hash = :erlang.phash2({tool_use.tool, tool_use.input})
    is_duplicate = MapSet.member?(state.tool_call_hashes, call_hash)

    # Auto-checkpoint before write operations
    if tool_use.tool in ["file_edit", "file_write", "bash"] and
         Synapsis.Git.is_repo?(project_path) do
      Synapsis.Git.checkpoint(project_path, "synapsis pre-#{tool_use.tool}")
    end

    Task.Supervisor.async_nolink(Synapsis.Tool.TaskSupervisor, fn ->
      result =
        Synapsis.Tool.Executor.execute(tool_use.tool, tool_use.input, %{
          project_path: project_path,
          session_id: state.session_id,
          working_dir: project_path
        })

      case result do
        {:ok, output} ->
          final_output =
            if is_duplicate do
              output <>
                "\n\nWarning: This exact tool call was already made in this conversation turn. The same approach may not work. Try a different approach."
            else
              output
            end

          send(worker_pid, {:tool_result, tool_use.tool_use_id, final_output, false})

        {:error, reason} ->
          send(worker_pid, {:tool_result, tool_use.tool_use_id, inspect(reason), true})
      end
    end)
  end

  defp continue_after_tools([], state) do
    # Increment iteration count and check limit
    iteration_count = state.iteration_count + 1

    max_iterations =
      Application.get_env(:synapsis_core, :max_tool_iterations, @max_tool_iterations)

    if iteration_count >= max_iterations do
      Logger.warning("max_tool_iterations_reached",
        session_id: state.session_id,
        iterations: iteration_count
      )

      # Persist a system message about the limit
      limit_part = %Synapsis.Part.Text{
        content:
          "Reached maximum tool iterations (#{max_iterations}). Stopping to prevent infinite loop."
      }

      {:ok, _msg} =
        %Message{}
        |> Message.changeset(%{
          session_id: state.session_id,
          role: "assistant",
          parts: [limit_part],
          token_count: 20
        })
        |> Repo.insert()

      update_session_status(state.session_id, "idle")
      broadcast(state.session_id, "max_iterations", %{iterations: iteration_count})
      broadcast(state.session_id, "session_status", %{status: "idle"})

      {:noreply,
       %{state | status: :idle, stream_ref: nil, tool_uses: [], iteration_count: iteration_count}}
    else
      state = %{state | iteration_count: iteration_count}

      # All tools processed, continue the agent loop
      messages = load_messages(state.session_id)

      request =
        Synapsis.MessageBuilder.build_request(messages, state.agent, state.session.provider)

      case SessionStream.start_stream(request, state.provider_config, state.session.provider) do
        {:ok, ref} ->
          update_session_status(state.session_id, "streaming")
          broadcast(state.session_id, "session_status", %{status: "streaming"})

          {:noreply,
           %{
             state
             | status: :streaming,
               stream_ref: ref,
               pending_text: "",
               tool_uses: [],
               pending_reasoning: ""
           }}

        {:error, reason} ->
          update_session_status(state.session_id, "error")
          broadcast(state.session_id, "error", %{message: inspect(reason)})
          {:noreply, %{state | status: :error}}
      end
    end
  end

  defp continue_after_tools(remaining, state) do
    {:noreply, %{state | tool_uses: remaining}}
  end

  defp load_messages(session_id) do
    import Ecto.Query

    Message
    |> where([m], m.session_id == ^session_id)
    |> order_by([m], asc: m.inserted_at)
    |> Repo.all()
  end

  defp update_session_status(session_id, status) do
    Session
    |> Repo.get!(session_id)
    |> Session.status_changeset(status)
    |> Repo.update!()
  end

  defp broadcast(session_id, event, payload) do
    Phoenix.PubSub.broadcast(
      Synapsis.PubSub,
      "session:#{session_id}",
      {event, payload}
    )
  end

  defp resolve_provider_config(provider_name) do
    case Synapsis.Provider.Registry.get(provider_name) do
      {:ok, config} ->
        config

      {:error, _} ->
        # Fallback: try DB directly
        case Synapsis.Providers.get_by_name(provider_name) do
          {:ok, provider} ->
            %{
              api_key: provider.api_key_encrypted,
              base_url: provider.base_url || default_base_url(provider_name),
              type: provider.type
            }

          {:error, _} ->
            # Final fallback: config files + env vars
            auth = Synapsis.Config.load_auth()
            api_key = get_in(auth, [provider_name, "apiKey"]) || get_env_key(provider_name)
            %{api_key: api_key, base_url: default_base_url(provider_name)}
        end
    end
  end

  defp get_env_key("anthropic"), do: System.get_env("ANTHROPIC_API_KEY")
  defp get_env_key("openai"), do: System.get_env("OPENAI_API_KEY")
  defp get_env_key("google"), do: System.get_env("GOOGLE_API_KEY")
  defp get_env_key(_), do: nil

  defp default_base_url("anthropic"), do: "https://api.anthropic.com"
  defp default_base_url("openai"), do: "https://api.openai.com"
  defp default_base_url("google"), do: "https://generativelanguage.googleapis.com"
  defp default_base_url("local"), do: "http://localhost:11434"
  defp default_base_url(_), do: "https://api.openai.com"

  defp find_pending_tool(tool_uses, tool_use_id) do
    Enum.find(tool_uses, fn tu -> tu.tool_use_id == tool_use_id end)
  end

  defp reject_tool(tool_uses, tool_use_id) do
    Enum.reject(tool_uses, fn tu -> tu.tool_use_id == tool_use_id end)
  end

  defp retriable_error?(reason) when is_binary(reason) do
    String.contains?(reason, "429") or
      String.contains?(reason, "500") or
      String.contains?(reason, "502") or
      String.contains?(reason, "503") or
      String.contains?(reason, "timeout") or
      String.contains?(reason, "connection") or
      String.contains?(reason, "disconnected")
  end

  defp retriable_error?(_), do: false
end
