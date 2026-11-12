defmodule SynapsisLocalAgents.Codex do
  @moduledoc """
  Local agent adapter for the Codex app-server, via `SamgitaCodexDriver.Session`
  over stdio (`codex app-server --listen stdio://`).

  This process owns the Session and receives its events; requests run in the
  caller against the Session pid so a long request never delays streaming.
  Approval requests are accepted automatically (yolo, docs/design.md §5) and
  surfaced as `:interaction` events. Native payloads are never logged.
  """
  @behaviour SynapsisLocalAgents.Adapter
  use GenServer

  require Logger
  alias SamgitaCodexDriver.Session
  alias SamgitaProtocolCodex.Error
  alias SynapsisLocalAgents.Event

  @request_timeout 30_000
  @call_timeout @request_timeout + 5_000
  @approval_methods ~w(
    item/commandExecution/requestApproval item/fileChange/requestApproval
    item/permissions/requestApproval applyPatchApproval execCommandApproval
  )

  # ── Adapter API ───────────────────────────────────────────────────────────

  @impl SynapsisLocalAgents.Adapter
  def start_link(config, owner), do: GenServer.start_link(__MODULE__, {config, owner})

  @impl SynapsisLocalAgents.Adapter
  def list_threads(pid) do
    with {:ok, result} <- request(pid, "thread/list", %{}, effect: :read) do
      {:ok, Enum.map(result["data"] || [], &thread_summary/1)}
    end
  end

  @impl SynapsisLocalAgents.Adapter
  def start_thread(pid) do
    with {:ok, result} <- request(pid, "thread/start", %{}), do: {:ok, %{id: result["thread"]["id"]}}
  end

  # Codex returns a thread's turns from `thread/resume` (`thread/read` with
  # `includeTurns` is unsupported). A thread created in this process has no
  # rollout yet: it is already loaded and has no history.
  @impl SynapsisLocalAgents.Adapter
  def read_thread(pid, thread_id) do
    case request(pid, "thread/resume", %{"threadId" => thread_id}) do
      {:ok, result} ->
        {:ok, %{id: thread_id, turns: Enum.map(get_in(result, ["thread", "turns"]) || [], &turn/1)}}

      {:error, error} ->
        if no_rollout?(error) do
          with {:ok, _} <- request(pid, "thread/read", %{"threadId" => thread_id}, effect: :read),
               do: {:ok, %{id: thread_id, turns: []}}
        else
          {:error, error}
        end
    end
  end

  @impl SynapsisLocalAgents.Adapter
  def resume_thread(pid, thread_id) do
    case request(pid, "thread/resume", %{"threadId" => thread_id}) do
      {:ok, result} -> {:ok, %{id: get_in(result, ["thread", "id"]) || thread_id}}
      {:error, error} -> if no_rollout?(error), do: {:ok, %{id: thread_id}}, else: {:error, error}
    end
  end

  defp no_rollout?(%{code: :upstream_error, message: message}) when is_binary(message),
    do: String.contains?(message, "no rollout found")

  defp no_rollout?(_), do: false

  @impl SynapsisLocalAgents.Adapter
  def start_turn(pid, thread_id, text) do
    with {:ok, result} <-
           request(pid, "turn/start", %{"threadId" => thread_id, "input" => [text_input(text)]}),
         do: {:ok, %{turn_id: result["turn"]["id"]}}
  end

  @impl SynapsisLocalAgents.Adapter
  def steer_turn(pid, thread_id, turn_id, text) do
    params = %{"threadId" => thread_id, "expectedTurnId" => turn_id, "input" => [text_input(text)]}
    with {:ok, _} <- request(pid, "turn/steer", params), do: :ok
  end

  @impl SynapsisLocalAgents.Adapter
  def interrupt_turn(pid, thread_id, turn_id) do
    with {:ok, _} <- request(pid, "turn/interrupt", %{"threadId" => thread_id, "turnId" => turn_id}),
         do: :ok
  end

  @impl SynapsisLocalAgents.Adapter
  def stop(pid), do: GenServer.call(pid, :stop, @call_timeout)

  defp request(pid, method, params, opts \\ []) do
    with {:ok, session} <- GenServer.call(pid, :session) do
      session
      |> Session.request(method, params, Keyword.put(opts, :timeout_ms, @request_timeout))
      |> result()
    end
  end

  # A reply the pinned schema rejects (e.g. a newer Codex adding fields) still
  # carries the upstream result; read it rather than reporting a failure.
  defp result({:ok, wire}), do: {:ok, wire["result"] || %{}}

  defp result({:error, %Error{code: :unvalidated_response, wire: %{"result" => result}}}),
    do: {:ok, result}

  defp result({:error, %Error{code: :upstream_error, wire: %{"error" => %{"message" => message}}}})
       when is_binary(message),
       do: {:error, %{code: :upstream_error, message: String.slice(message, 0, 300)}}

  defp result({:error, %Error{code: code}}), do: {:error, code}

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl GenServer
  def init({config, owner}) do
    Process.flag(:trap_exit, true)
    {:ok, %{config: config, owner: owner, session: nil}, {:continue, :boot}}
  end

  @impl GenServer
  def handle_continue(:boot, state) do
    with {:ok, session} <- Session.start_link(transport: transport(state.config), owner: self()),
         {:ok, _} <-
           Session.initialize(session, %{"name" => "synapsis", "version" => version()}, %{"experimentalApi" => false},
             timeout_ms: @request_timeout
           ) do
      Logger.info("codex_session_ready", agent_id: state.config.id)
      notify(state, %Event{type: :status, data: %{state: :running}})
      {:noreply, %{state | session: session}}
    else
      {:error, %Error{code: code}} -> {:stop, {:codex_init_failed, code}, state}
      {:error, reason} -> {:stop, {:codex_init_failed, reason}, state}
    end
  end

  @impl GenServer
  def handle_call(:session, _from, %{session: nil} = state), do: {:reply, {:error, :not_ready}, state}
  def handle_call(:session, _from, state), do: {:reply, {:ok, state.session}, state}

  def handle_call(:stop, _from, %{session: session} = state) do
    if session, do: Session.close(session)
    {:stop, :normal, :ok, %{state | session: nil}}
  end

  @impl GenServer
  def handle_info({:codex_driver, session, :events_available}, %{session: session} = state) do
    drain(state)
    {:noreply, state}
  end

  def handle_info({:codex_driver, session, {:gap, %{reason: reason}}}, %{session: session} = state) do
    {:stop, {:codex_disconnected, reason}, state}
  end

  def handle_info({:EXIT, session, reason}, %{session: session} = state) do
    {:stop, {:codex_exited, reason}, %{state | session: nil}}
  end

  def handle_info({:EXIT, owner, reason}, %{owner: owner} = state), do: {:stop, reason, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{session: session}) when is_pid(session) do
    Session.close(session)
  catch
    :exit, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  # ── Events ────────────────────────────────────────────────────────────────

  defp drain(state) do
    case Session.drain(state.session, 100) do
      {:ok, []} ->
        :ok

      {:ok, events} ->
        Enum.each(events, &handle_event(&1, state))
        drain(state)

      {:error, _} ->
        :ok
    end
  end

  defp handle_event(%{kind: kind, wire: %{"method" => method, "params" => params}}, state)
       when kind in [:notification, :unvalidated_notification] do
    case notification(method, params) do
      nil -> :ok
      event -> notify(state, event)
    end
  end

  defp handle_event(%{kind: :server_request, handle: handle, wire: %{"method" => method} = wire}, state) do
    params = wire["params"] || %{}

    if method in @approval_methods do
      Session.respond(state.session, handle, {:ok, %{"decision" => "accept"}})

      notify(state, %Event{
        type: :interaction,
        thread_id: params["threadId"],
        turn_id: params["turnId"],
        item_id: params["itemId"],
        data: %{method: method, decision: "accept"}
      })
    else
      Logger.info("codex_server_request_unsupported", method: method)
      Session.respond(state.session, handle, {:error, %{"code" => -32601, "message" => "unsupported by synapsis"}})
    end
  end

  defp handle_event(_event, _state), do: :ok

  defp notification("thread/started", p),
    do: %Event{type: :thread_started, thread_id: get_in(p, ["thread", "id"]) || p["threadId"]}

  defp notification("turn/started", p),
    do: %Event{type: :turn_started, thread_id: p["threadId"], turn_id: get_in(p, ["turn", "id"])}

  defp notification("turn/completed", p) do
    %Event{
      type: :turn_completed,
      thread_id: p["threadId"],
      turn_id: get_in(p, ["turn", "id"]),
      data: %{status: get_in(p, ["turn", "status"]), error: get_in(p, ["turn", "error", "message"])}
    }
  end

  defp notification("item/agentMessage/delta", p) do
    %Event{type: :item_delta, thread_id: p["threadId"], turn_id: p["turnId"], item_id: p["itemId"],
      data: %{delta: p["delta"]}}
  end

  defp notification(method, p) when method in ["item/started", "item/completed"] do
    item = p["item"] || %{}
    type = if method == "item/started", do: :item_started, else: :item_completed

    %Event{type: type, thread_id: p["threadId"], turn_id: p["turnId"], item_id: item["id"],
      data: %{item: %{type: item["type"], text: item_text(item)}}}
  end

  defp notification(_method, _params), do: nil

  defp notify(state, event), do: send(state.owner, {:local_agent_event, %{event | agent_id: state.config.id}})

  # ── Mapping helpers ───────────────────────────────────────────────────────

  defp thread_summary(thread) do
    %{id: thread["id"], title: thread["name"] || thread["preview"], updated_at: unix_iso(thread["updatedAt"])}
  end

  defp turn(turn) do
    items =
      for item <- turn["items"] || [], item["type"] in ["userMessage", "agentMessage"] do
        %{id: item["id"], role: if(item["type"] == "userMessage", do: :user, else: :agent), text: item_text(item)}
      end

    %{id: turn["id"], status: turn["status"], items: items}
  end

  defp item_text(%{"type" => "agentMessage", "text" => text}), do: text

  defp item_text(%{"type" => "userMessage", "content" => content}) do
    content |> Enum.filter(&(&1["type"] == "text")) |> Enum.map_join("\n", & &1["text"])
  end

  defp item_text(_), do: nil

  defp unix_iso(seconds) when is_integer(seconds),
    do: seconds |> DateTime.from_unix!() |> DateTime.to_iso8601()

  defp unix_iso(_), do: nil

  defp text_input(text), do: %{"type" => "text", "text" => text}

  defp transport(config),
    do: Application.get_env(:synapsis_local_agents, :codex_transport) || stdio_transport(config)

  # Stdio's default inherited variables (SamgitaCodexDriver.Transport.Stdio @inherit).
  @default_inherit ~w(PATH LANG LC_ALL LC_CTYPE TMPDIR TEMP TMP SystemRoot WINDIR)

  @doc """
  Stdio transport for `config`. Besides the driver's minimal environment, Codex
  receives the variables its own `config.toml` declares as provider `env_key`s
  (e.g. an API token), so configured providers authenticate as in a shell.
  """
  def stdio_transport(config) do
    opts =
      [
        executable: config.executable,
        args: config.args,
        codex_home: config.codex_home,
        env: %{"HOME" => System.user_home!()},
        inherit_env: Enum.uniq(@default_inherit ++ declared_env_keys(config.codex_home))
      ] ++ if(config.cwd, do: [cwd: config.cwd], else: [])

    {SamgitaCodexDriver.Transport.Stdio, opts}
  end

  defp declared_env_keys(nil), do: []

  defp declared_env_keys(codex_home) do
    case Toml.decode_file(Path.join(codex_home, "config.toml")) do
      {:ok, config} -> collect_env_keys(config)
      {:error, _} -> []
    end
  end

  defp collect_env_keys(map) when is_map(map) do
    Enum.flat_map(map, fn
      {"env_key", key} when is_binary(key) -> [key]
      {_key, value} -> collect_env_keys(value)
    end)
  end

  defp collect_env_keys(list) when is_list(list), do: Enum.flat_map(list, &collect_env_keys/1)
  defp collect_env_keys(_), do: []

  defp version, do: :synapsis_local_agents |> Application.spec(:vsn) |> to_string()
end
