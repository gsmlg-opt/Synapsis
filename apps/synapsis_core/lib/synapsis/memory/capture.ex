defmodule Synapsis.Memory.Capture do
  @moduledoc """
  Best-effort, bounded lifecycle capture for the supported Synapsis 1.0 contract.

  Admission is nonblocking and bounded to 32 events (four active tasks). Each
  event shares a two-second deadline across queueing, its durable reservation
  and HTTP. A reservation is never replayed, including after an uncertain write
  or process restart. Capture loss never affects session execution.
  """
  use GenServer

  alias Synapsis.Memory.{HostAgent, Settings}
  alias Synapsis.Session.Store

  @limit 32
  @workers 4
  @budget 2_000
  @bytes 65_536
  @hooks ~w(session-start user-prompt-submit post-tool-use session-end)

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, name, name: name)
  end

  @doc "Admit a public event without waiting for configuration, storage or HTTP."
  def emit(context, hook, payload, server \\ __MODULE__) do
    with true <- valid?(context, hook, payload),
         table when table != :undefined <- :ets.whereis(server),
         [{:owner, owner}] <- :ets.lookup(table, :owner) do
      if :ets.update_counter(table, :slots, {2, 1}) <= @limit do
        event = {context, hook, payload, System.monotonic_time(:millisecond) + @budget}
        send(owner, {:capture, event})
      else
        :ets.update_counter(table, :slots, {2, -1})
      end
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @impl true
  def init(name) do
    Process.flag(:trap_exit, true)
    table = :ets.new(name, [:named_table, :public, write_concurrency: true])
    :ets.insert(table, [{:owner, self()}, {:slots, 0}])
    {:ok, %{table: table, queue: :queue.new(), tasks: %{}}}
  end

  @impl true
  def handle_info({:capture, event}, state),
    do: {:noreply, drain(%{state | queue: :queue.in(event, state.queue)})}

  def handle_info({ref, _result}, state) when is_map_key(state.tasks, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(state, ref)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state)
      when is_map_key(state.tasks, ref),
      do: {:noreply, finish(state, ref)}

  def handle_info({:expire, ref}, state) do
    case state.tasks[ref] do
      %{task: task} -> Task.shutdown(task, :brutal_kill)
      _ -> :ok
    end

    {:noreply, if(Map.has_key?(state.tasks, ref), do: finish(state, ref), else: state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    for {_ref, %{task: task}} <- state.tasks, do: Task.shutdown(task, :brutal_kill)
    :ok
  end

  @impl true
  def format_status(status), do: Map.put(status, :state, :redacted)

  defp finish(state, ref) do
    %{timer: timer} = state.tasks[ref]
    Process.cancel_timer(timer)
    :ets.update_counter(state.table, :slots, {2, -1})
    drain(%{state | tasks: Map.delete(state.tasks, ref)})
  end

  defp drain(state) when map_size(state.tasks) >= @workers, do: state

  defp drain(state) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        state

      {{:value, {_context, _hook, _payload, deadline} = event}, rest} ->
        state = %{state | queue: rest}

        if deadline <= System.monotonic_time(:millisecond) do
          :ets.update_counter(state.table, :slots, {2, -1})
          drain(state)
        else
          task =
            Task.Supervisor.async_nolink(Synapsis.Tool.TaskSupervisor, fn -> deliver(event) end)

          timer =
            Process.send_after(
              self(),
              {:expire, task.ref},
              max(0, deadline - System.monotonic_time(:millisecond))
            )

          drain(%{state | tasks: Map.put(state.tasks, task.ref, %{task: task, timer: timer})})
        end
    end
  end

  defp deliver({context, hook, payload, deadline}) do
    with {:ok, source} <- Settings.host_source(),
         {:ok, remaining} <- remaining(deadline),
         suffix = receipt_key(hook, payload),
         :not_found <- Store.value_snapshot(context.session_id, suffix, timeout: remaining),
         envelope = envelope(context, payload),
         {:ok, remaining} <- remaining(deadline),
         :ok <-
           Store.put_value_if_revision(
             context.session_id,
             suffix,
             %{"state" => "reserved", "hook" => hook, "event" => envelope},
             0,
             timeout: remaining
           ),
         {:ok, current} <- Settings.host_source(),
         true <- current == source,
         {:ok, _} <- HostAgent.capture(source, hook, envelope, deadline: deadline) do
      :ok
    else
      _ -> :ok
    end
  end

  defp envelope(context, payload) do
    %{
      "schema_version" => "1.0",
      "event_id" => Ecto.UUID.generate(),
      "session_id" => context.session_id,
      "cwd" => context.cwd,
      "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
      "agent_id" => context.agent_id,
      "payload" => payload
    }
  end

  defp receipt_key(hook, payload) do
    logical =
      case hook do
        "user-prompt-submit" -> payload["message_id"]
        "post-tool-use" -> payload["tool_call_id"]
        # TODO(upstream): gsmlg-opt/backplane#176 — the host currently keys
        # start/end by durable session, so only the first pair is captured until
        # distinct Worker lifecycle identities are supported upstream.
        _ -> "session"
      end

    digest = :crypto.hash(:sha256, hook <> ":" <> logical) |> Base.url_encode64(padding: false)
    "memory_capture_" <> digest
  end

  defp valid?(%{session_id: session, cwd: cwd, agent_id: agent}, hook, payload) do
    hook in @hooks and is_binary(session) and Ecto.UUID.cast(session) == {:ok, session} and
      is_binary(cwd) and Path.type(cwd) == :absolute and byte_size(cwd) <= 4096 and
      is_binary(agent) and byte_size(agent) in 1..512 and
      is_map(payload) and :erlang.external_size(payload) <= @bytes and
      case hook do
        "session-start" ->
          payload == %{}

        "session-end" ->
          is_binary(payload["reason"])

        "user-prompt-submit" ->
          is_binary(payload["message_id"]) and is_binary(payload["content"])

        "post-tool-use" ->
          is_binary(payload["tool_call_id"]) and is_binary(payload["tool_name"]) and
            is_boolean(payload["is_error"]) and Map.has_key?(payload, "result")
      end
  end

  defp valid?(_, _, _), do: false

  defp remaining(deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      value when value > 0 -> {:ok, min(value, @budget)}
      _ -> {:error, :timeout}
    end
  end
end
