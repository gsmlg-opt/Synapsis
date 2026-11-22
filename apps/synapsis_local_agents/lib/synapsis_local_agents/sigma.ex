defmodule SynapsisLocalAgents.Sigma do
  @moduledoc """
  Local agent adapter for a running Sigma, over its samgita_protocol 1.0 host
  (`/app-server`) with `SamgitaProtocolWebSocket.Client`.

  Sigma is a long-running service that Synapsis does not spawn: starting this
  adapter connects and initializes (`sessions.v1`, `streaming.v1`,
  `cancellation.v1`), stopping it disconnects. The Bearer token is the agent's
  token from `Synapsis.LocalAgentConfigs.rotate_token/1`.

  This process owns the client connection and receives its notifications;
  requests run in the caller against the client pid. New threads are created
  in the configured `repository`.

  The client neither reports a closed connection nor keeps an idle one alive
  (Sigma closes it after 60 s without traffic), so a lost connection is found
  by the next request: the adapter then reconnects, re-initializes and resumes
  the threads it follows, and a request that was never sent is retried once.
  If Sigma cannot be reached the adapter stops and the Runner reports a crash.
  """
  @behaviour SynapsisLocalAgents.Adapter
  use GenServer

  require Logger
  alias SamgitaProtocol.Error
  alias SamgitaProtocolWebSocket.Client
  alias Synapsis.{LocalAgentConfigs, LocalAgentThreads}
  alias SynapsisLocalAgents.Event

  @capabilities ["sessions.v1", "streaming.v1", "cancellation.v1"]
  @required ["sessions.v1", "streaming.v1"]
  @connect_timeout 5_000
  @request_timeout 30_000
  @thread_limit 50
  # Request outcomes that mean the connection is gone.
  @lost ~w(disconnected ambiguous_disconnect not_initialized stale_connection)
  @reconnect_timeout 2 * @connect_timeout + 5_000

  # ── Adapter API ───────────────────────────────────────────────────────────

  @impl SynapsisLocalAgents.Adapter
  def start_link(config, owner), do: GenServer.start_link(__MODULE__, {config, owner})

  @impl SynapsisLocalAgents.Adapter
  def list_threads(pid) do
    # TODO(upstream): gsmlg-opt/Samgita#2 — list through `thread/list` once available.
    with {:ok, %{config: config}} <- conn(pid),
         do: LocalAgentThreads.list(config.id, @thread_limit)
  end

  @impl SynapsisLocalAgents.Adapter
  def start_thread(pid) do
    with {:ok, %{config: config}} <- conn(pid),
         {:ok, %{"thread_id" => thread_id}} <-
           request(pid, "thread/start", %{"metadata" => %{"repository" => config.repository}},
             mutating: true
           ) do
      GenServer.cast(pid, {:follow, thread_id})

      case LocalAgentThreads.record(config.id, thread_id) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("sigma_thread_not_recorded",
            agent_id: config.id,
            reason: inspect(reason)
          )
      end

      {:ok, %{id: thread_id}}
    end
  end

  @impl SynapsisLocalAgents.Adapter
  def read_thread(pid, thread_id) do
    with {:ok, %{"thread" => thread}} <- request(pid, "thread/read", %{"thread_id" => thread_id}),
         do: {:ok, %{id: thread_id, turns: history(thread)}}
  end

  @impl SynapsisLocalAgents.Adapter
  def resume_thread(pid, thread_id) do
    with {:ok, result} <-
           request(pid, "thread/resume", %{"thread_id" => thread_id}, mutating: true) do
      GenServer.cast(pid, {:follow, thread_id})
      {:ok, %{id: result["thread_id"] || thread_id}}
    end
  end

  @impl SynapsisLocalAgents.Adapter
  def start_turn(pid, thread_id, text) do
    params = %{"thread_id" => thread_id, "input" => [text_input(text)]}

    with {:ok, %{"turn_id" => turn_id}} <- request(pid, "turn/start", params, mutating: true),
         do: {:ok, %{turn_id: turn_id}}
  end

  @impl SynapsisLocalAgents.Adapter
  def steer_turn(pid, thread_id, turn_id, text) do
    params = %{"thread_id" => thread_id, "turn_id" => turn_id, "input" => [text_input(text)]}
    with {:ok, _} <- request(pid, "turn/steer", params, mutating: true), do: :ok
  end

  @impl SynapsisLocalAgents.Adapter
  def interrupt_turn(pid, thread_id, turn_id) do
    params = %{"thread_id" => thread_id, "turn_id" => turn_id}
    with {:ok, _} <- request(pid, "turn/interrupt", params, mutating: true), do: :ok
  end

  @impl SynapsisLocalAgents.Adapter
  def stop(pid), do: GenServer.call(pid, :stop, @connect_timeout + 5_000)

  defp conn(pid), do: GenServer.call(pid, :conn, @connect_timeout)

  defp request(pid, method, params, opts \\ []) do
    with {:ok, conn} <- conn(pid), do: send_request(pid, conn, method, params, opts, 1)
  catch
    :exit, reason -> {:error, {:sigma_unavailable, short(reason)}}
  end

  # WORKAROUND(upstream): gsmlg-opt/Samgita#4 — reconnect when the client
  # reports the loss through a request; drop once it notifies and keeps alive.
  defp send_request(pid, conn, method, params, opts, retries) do
    case Client.request(conn.client, method, params, request_opts(opts)) do
      {:ok, result} ->
        {:ok, result}

      # Refused before sending: reconnect and send it once more.
      {:error, %Error{code: "not_initialized"}} when retries > 0 ->
        with {:ok, conn} <-
               GenServer.call(pid, {:reconnect, conn.generation}, @reconnect_timeout),
             do: send_request(pid, conn, method, params, opts, retries - 1)

      {:error, %Error{code: code} = error} ->
        if code in @lost, do: send(pid, {:connection_lost, conn.generation})
        {:error, error_of(error)}
    end
  end

  defp request_opts(opts) do
    [timeout_ms: @request_timeout] ++
      if(opts[:mutating], do: [command_id: Ecto.UUID.generate()], else: [])
  end

  defp error_of(%Error{code: code, details: %{"reason" => reason}}) when is_binary(reason),
    do: %{code: code, reason: reason}

  defp error_of(%Error{code: code}), do: %{code: code}

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl GenServer
  def init({config, owner}) do
    Process.flag(:trap_exit, true)
    state = %{config: config, owner: owner, client: nil, generation: 0, followed: MapSet.new()}
    {:ok, state, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, %{config: config} = state) do
    with {:ok, token} <- LocalAgentConfigs.resolve_token(config.id),
         {:ok, client} <- connect(config.url, token),
         _ref = Process.monitor(client),
         {:ok, %{"connection_id" => connection_id}} <- initialize(client) do
      Logger.info("sigma_connected", agent_id: config.id, connection_id: connection_id)
      notify(state, %Event{type: :status, data: %{state: :running}})
      {:noreply, %{state | client: client}}
    else
      {:error, %Error{code: code}} -> {:stop, {:sigma_connect_failed, code}, state}
      {:error, reason} -> {:stop, {:sigma_connect_failed, reason}, state}
    end
  end

  defp connect(url, token) do
    Client.connect(url,
      token: token,
      capabilities: @capabilities,
      connect_timeout_ms: @connect_timeout,
      request_timeout_ms: @request_timeout
    )
  end

  defp initialize(client) do
    params = %{
      "versions" => ["1.0"],
      "capabilities" => @capabilities,
      "required_capabilities" => @required
    }

    Client.request(client, "connection/initialize", params, timeout_ms: @connect_timeout)
  end

  @impl GenServer
  def handle_call(:conn, _from, %{client: nil} = state), do: {:reply, {:error, :not_ready}, state}

  def handle_call(:conn, _from, state), do: {:reply, {:ok, conn_of(state)}, state}

  # Only the first caller that saw the lost connection reconnects; the others
  # get the connection that replaced it.
  def handle_call({:reconnect, generation}, _from, %{generation: generation} = state) do
    case reconnect(state) do
      {:ok, state} -> {:reply, {:ok, conn_of(state)}, state}
      {:error, reason} -> {:stop, {:sigma_disconnected, reason}, {:error, :disconnected}, state}
    end
  end

  def handle_call({:reconnect, _stale}, _from, state), do: {:reply, {:ok, conn_of(state)}, state}

  def handle_call(:stop, _from, state) do
    close(state.client)
    {:stop, :normal, :ok, %{state | client: nil}}
  end

  @impl GenServer
  def handle_cast({:follow, thread_id}, state),
    do: {:noreply, %{state | followed: MapSet.put(state.followed, thread_id)}}

  @impl GenServer
  def handle_info({:samgita_protocol, client, effect}, %{client: client} = state),
    do: handle_effect(effect, state)

  def handle_info({:connection_lost, generation}, %{generation: generation} = state) do
    case reconnect(state) do
      {:ok, state} -> {:noreply, state}
      {:error, reason} -> {:stop, {:sigma_disconnected, reason}, state}
    end
  end

  def handle_info({:connection_lost, _stale}, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, client, reason}, %{client: client} = state),
    do: {:stop, {:sigma_disconnected, short(reason)}, %{state | client: nil}}

  def handle_info({:EXIT, owner, reason}, %{owner: owner} = state), do: {:stop, reason, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state), do: close(state.client)

  defp conn_of(state),
    do: %{client: state.client, config: state.config, generation: state.generation}

  defp reconnect(state) do
    with :ok <- Client.reconnect(state.client),
         {:ok, _} <- initialize(state.client) do
      Logger.info("sigma_reconnected", agent_id: state.config.id)
      resume_followed(state.client, state.followed)
      {:ok, %{state | generation: state.generation + 1}}
    else
      {:error, %Error{code: code}} -> {:error, code}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, short(reason)}
  end

  # A new connection follows nothing: resume the followed threads so their
  # notifications (and an active turn's backlog) reach it. Runs outside this
  # process, which must keep draining those notifications meanwhile.
  defp resume_followed(client, followed) do
    Task.Supervisor.start_child(SynapsisLocalAgents.TaskSupervisor, fn ->
      for thread_id <- followed do
        case Client.request(
               client,
               "thread/resume",
               %{"thread_id" => thread_id},
               request_opts(mutating: true)
             ) do
          {:ok, _} -> :ok
          {:error, %Error{code: code}} -> Logger.warning("sigma_resume_failed", code: code)
        end
      end
    end)
  end

  defp close(nil), do: :ok

  defp close(client) do
    Client.close(client)
  catch
    :exit, _ -> :ok
  end

  # ── Events ────────────────────────────────────────────────────────────────

  defp handle_effect({:notification, %{"method" => method, "params" => params} = message}, state) do
    case notification(method, params) do
      nil -> :ok
      event -> notify(state, event)
    end

    ack(state.client, message)
    {:noreply, state}
  end

  # Host-initiated requests (approvals) are outside the negotiated groups.
  defp handle_effect({:request, message}, state) do
    Logger.info("sigma_request_unsupported", method: message["method"])
    _ = Client.reply(state.client, message, {:error, Error.new("unsupported_method")})
    {:noreply, state}
  end

  # A frame the client could not accept: it has already disconnected.
  defp handle_effect({:error, %Error{code: code}}, state),
    do: {:stop, {:sigma_disconnected, code}, state}

  defp handle_effect(_effect, state), do: {:noreply, state}

  # Processed: a later stream/resume would start after this cursor.
  defp ack(client, %{"stream_id" => stream, "cursor" => cursor}),
    do: Client.ack_cursor(client, stream, cursor)

  defp ack(_client, _message), do: :ok

  defp notification("thread/started", p),
    do: %Event{type: :thread_started, thread_id: p["thread_id"]}

  defp notification("turn/started", p),
    do: %Event{type: :turn_started, thread_id: p["thread_id"], turn_id: p["turn_id"]}

  defp notification("turn/completed", p) do
    %Event{
      type: :turn_completed,
      thread_id: p["thread_id"],
      turn_id: p["turn_id"],
      data: %{status: p["status"], error: nil}
    }
  end

  defp notification("item/delta", p) do
    %Event{
      type: :item_delta,
      thread_id: p["thread_id"],
      turn_id: p["turn_id"],
      item_id: p["item_id"],
      data: %{delta: p["delta"]}
    }
  end

  defp notification(method, p) when method in ["item/started", "item/completed"] do
    %Event{
      type: if(method == "item/started", do: :item_started, else: :item_completed),
      thread_id: p["thread_id"],
      turn_id: p["turn_id"],
      item_id: p["item_id"],
      data: %{item: item(p["item"] || %{})}
    }
  end

  defp notification(_method, _params), do: nil

  defp notify(state, event),
    do: send(state.owner, {:local_agent_event, %{event | agent_id: state.config.id}})

  # ── Mapping helpers ───────────────────────────────────────────────────────

  # Item types follow the unified vocabulary the page renders (`agentMessage`).
  defp item(%{"type" => "message", "role" => "assistant"} = item),
    do: %{type: "agentMessage", text: content_text(item["content"])}

  defp item(%{"type" => "message", "role" => "user"} = item),
    do: %{type: "userMessage", text: content_text(item["content"])}

  defp item(%{"type" => "tool", "name" => name}), do: %{type: "tool", text: name}
  defp item(item), do: %{type: item["type"], text: nil}

  defp content_text(text) when is_binary(text), do: text

  defp content_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.filter(&(is_map(&1) and &1["type"] == "text" and is_binary(&1["text"])))
    |> Enum.map_join("\n", & &1["text"])
  end

  defp content_text(_), do: nil

  # Sigma returns the newest messages without turn boundaries: one history turn.
  defp history(%{"messages" => messages}) when is_list(messages) do
    items =
      for %{"id" => id, "role" => role} = message <- messages,
          role in ["user", "assistant"],
          text = history_text(message),
          text != "" do
        %{id: id, role: if(role == "user", do: :user, else: :agent), text: text}
      end

    [%{id: "history", status: "completed", items: items}]
  end

  defp history(_thread), do: []

  defp history_text(message) do
    text = if is_binary(message["text"]), do: message["text"], else: ""

    case message["tools"] do
      [_ | _] = tools -> String.trim(text <> "\n\n(tools: " <> Enum.join(tools, ", ") <> ")")
      _ -> text
    end
  end

  defp text_input(text), do: %{"type" => "text", "text" => text}

  defp short(reason),
    do: reason |> inspect(limit: 5, printable_limit: 200) |> String.slice(0, 200)
end
