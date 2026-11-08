defmodule Synapsis.Browser.PortSession do
  @moduledoc """
  Session-owned, bounded transport for the managed Browser helper.

  Starting this process is dormant. The native resource owner must register it
  before calling `initialize/1`, which starts Node but leaves Chromium dormant.
  Browser actions are never retried. Only the helper can confirm browser cleanup;
  a Port exit alone is not that confirmation.
  """
  use GenServer, restart: :temporary

  @frame_limit 1_048_576
  @cleanup_timeout 12_000
  @initialize_timeout 10_000
  @close_retry_interval 25

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def initialize(pid), do: GenServer.call(pid, :initialize, @initialize_timeout + 1_000)

  def call(pid, action, args, timeout_ms),
    do:
      GenServer.call(
        pid,
        {:call, action, args, timeout_ms},
        timeout_ms + @cleanup_timeout + 1_000
      )

  def cancel(pid), do: GenServer.call(pid, :cancel, @cleanup_timeout + 1_000)
  def close(pid), do: GenServer.call(pid, :close, @cleanup_timeout + 1_000)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(opts, :owner_pid)

    if is_pid(owner) and Process.alive?(owner) do
      {:ok,
       %{
         owner: owner,
         owner_monitor: Process.monitor(owner),
         node: Keyword.fetch!(opts, :node_executable),
         helper: Keyword.fetch!(opts, :helper_path),
         config: Keyword.fetch!(opts, :config),
         port: nil,
         phase: :dormant,
         generation: nil,
         sequence: 0,
         buffer: <<>>,
         pending: %{},
         active: nil,
         cancel: nil,
         closing: nil,
         close_frame: nil,
         close_retry: nil,
         close_deadline: nil,
         transport_teardown: false,
         cleanup_confirmed: false,
         exit_status: nil
       }}
    else
      {:stop, failure("unavailable", "Browser resource owner is unavailable", false)}
    end
  end

  @impl true
  def handle_call(:initialize, from, %{phase: :dormant} = state) do
    case open_port(state) do
      {:ok, port} ->
        state = %{state | port: port, phase: :initializing}
        {:noreply, request(state, :initialize, state.config, from, @initialize_timeout)}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call(:initialize, _from, %{phase: :ready} = state),
    do: {:reply, {:ok, %{"initialized" => true, "generation" => state.generation}}, state}

  def handle_call(:initialize, _from, state),
    do: {:reply, {:error, unavailable(state)}, state}

  def handle_call(
        {:call, action, args, timeout},
        from,
        %{phase: :ready, active: nil, cancel: nil} = state
      )
      when is_binary(action) and is_map(args) and is_integer(timeout) and
             timeout in 1..2_147_000_000 do
    params = %{
      "action" => action,
      "args" => args,
      "timeout_ms" => timeout,
      "generation" => state.generation
    }

    {:noreply, request(state, {:call, action}, params, from, timeout + @cleanup_timeout)}
  end

  def handle_call({:call, _, _, _}, _from, state),
    do: {:reply, {:error, unavailable(state)}, state}

  def handle_call(:cancel, _from, %{phase: :ready, active: nil, cancel: nil} = state),
    do: {:reply, {:ok, %{"cancelled" => false, "generation" => state.generation}}, state}

  def handle_call(:cancel, from, %{phase: :ready, cancel: nil, active: id} = state)
      when is_binary(id),
      do: {:noreply, request(state, :cancel, %{"id" => id}, from, @cleanup_timeout)}

  def handle_call(:cancel, _from, state),
    do: {:reply, {:error, unavailable(state)}, state}

  def handle_call(:close, _from, %{phase: :dormant} = state),
    do: {:reply, :ok, %{state | phase: :closed, cleanup_confirmed: true, exit_status: 0}}

  def handle_call(
        :close,
        _from,
        %{phase: :closed, cleanup_confirmed: true, exit_status: 0} = state
      ),
      do: {:reply, :ok, state}

  def handle_call(:close, from, %{closing: nil, port: port} = state) when is_port(port),
    do: {:noreply, begin_close(state, from)}

  def handle_call(:close, _from, state),
    do: {:reply, {:error, unavailable(state)}, state}

  @impl true
  def handle_info({port, {:data, _bytes}}, %{port: port, transport_teardown: true} = state),
    do: {:noreply, state}

  def handle_info({port, {:data, bytes}}, %{port: port} = state) do
    case consume(state.buffer <> bytes, %{state | buffer: <<>>}) do
      {:ok, state} ->
        {:noreply, state}

      {:error, state} ->
        {:noreply, transport_failed(state, "Browser helper returned an invalid frame")}
    end
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    state = %{state | exit_status: code, port: nil, buffer: <<>>}
    state = settle_exit(state)

    if Process.alive?(state.owner), do: {:noreply, state}, else: {:stop, :normal, state}
  end

  def handle_info({port, :eof}, %{port: port} = state), do: {:noreply, state}
  def handle_info({:EXIT, port, :normal}, %{port: port} = state), do: {:noreply, state}

  def handle_info({:EXIT, port, _reason}, %{port: port} = state),
    do: {:noreply, transport_failed(state, "Browser helper transport exited unexpectedly")}

  def handle_info({:request_timeout, id}, state) do
    case Map.get(state.pending, id) do
      nil ->
        {:noreply, state}

      %{kind: :close} ->
        {:noreply, teardown_unconfirmed(state, "Browser cleanup was not confirmed")}

      _request ->
        state =
          reply_request(state, id, {:error, unknown("Browser helper reply deadline elapsed")})

        {:noreply, begin_close(state, nil)}
    end
  end

  def handle_info({:retry_close, id}, %{closing: id, close_frame: frame} = state)
      when is_binary(frame) do
    if System.monotonic_time(:millisecond) < state.close_deadline do
      {:noreply, write_close(%{state | close_retry: nil})}
    else
      {:noreply, teardown_unconfirmed(state, "Browser close request could not be sent")}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_monitor: ref} = state) do
    if state.port do
      {:noreply, begin_close(state, nil)}
    else
      {:stop, :normal, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    pending =
      Map.new(state.pending, fn {id, request} ->
        {id, if(request.monitor == ref, do: %{request | from: nil, monitor: nil}, else: request)}
      end)

    state = %{state | pending: pending}

    if state.active && state.cancel == nil && state.phase == :ready do
      case Map.get(pending, state.active) do
        %{from: nil} ->
          {:noreply, request(state, :cancel, %{"id" => state.active}, nil, @cleanup_timeout)}

        _ ->
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp open_port(state) do
    {:ok,
     Port.open({:spawn_executable, String.to_charlist(state.node)}, [
       :binary,
       :exit_status,
       :use_stdio,
       :eof,
       args: [String.to_charlist(state.helper)]
     ])}
  rescue
    ArgumentError ->
      {:error, failure("unavailable", "Browser helper could not be started", false)}

    ErlangError ->
      {:error, failure("unavailable", "Browser helper could not be started", false)}
  end

  # At most one action, one cancel and one close are outstanding. Port writes use
  # nosuspend, so neither caller processes nor the broker queue unbounded writes.
  # Reserve cleanup and its deadline before writing: owner loss has no later
  # caller to retry a refused write. Retry only this unsent close frame/id.
  defp request(state, :close, _params, from, timeout) do
    id = Integer.to_string(state.sequence + 1)
    frame = Jason.encode!(%{version: 1, id: id, method: "close", params: %{}}) <> "\n"

    request = %{
      kind: :close,
      from: from,
      monitor: if(from, do: Process.monitor(elem(from, 0))),
      timer: Process.send_after(self(), {:request_timeout, id}, timeout)
    }

    write_close(%{
      state
      | sequence: state.sequence + 1,
        pending: Map.put(state.pending, id, request),
        closing: id,
        phase: :closing,
        close_frame: frame,
        close_deadline: System.monotonic_time(:millisecond) + timeout
    })
  end

  defp request(state, kind, params, from, timeout) do
    id = Integer.to_string(state.sequence + 1)
    method = if is_tuple(kind), do: "call", else: Atom.to_string(kind)

    with {:ok, encoded} <- Jason.encode(%{version: 1, id: id, method: method, params: params}),
         true <- byte_size(encoded) + 1 <= @frame_limit,
         true <- write(state.port, encoded <> "\n") do
      request = %{
        kind: kind,
        from: from,
        monitor: if(from, do: Process.monitor(elem(from, 0))),
        timer: Process.send_after(self(), {:request_timeout, id}, timeout)
      }

      state = %{
        state
        | sequence: state.sequence + 1,
          pending: Map.put(state.pending, id, request)
      }

      case kind do
        {:call, _} -> %{state | active: id}
        :cancel -> %{state | cancel: id}
        :initialize -> state
      end
    else
      _ ->
        if from,
          do:
            GenServer.reply(
              from,
              {:error, failure("unavailable", "Browser request was not sent", false)}
            )

        begin_close(%{state | phase: :uncertain}, nil)
    end
  end

  defp write_close(state) do
    if write(state.port, state.close_frame) do
      %{state | close_frame: nil}
    else
      timer = Process.send_after(self(), {:retry_close, state.closing}, @close_retry_interval)
      %{state | close_retry: timer}
    end
  end

  defp write(port, frame) do
    case Port.info(port, :queue_size) do
      {:queue_size, bytes} when bytes <= 2 * @frame_limit ->
        Port.command(port, frame, [:nosuspend])

      _ ->
        false
    end
  rescue
    ArgumentError -> false
  end

  defp consume(bytes, state) do
    case :binary.match(bytes, "\n") do
      :nomatch when byte_size(bytes) < @frame_limit ->
        {:ok, %{state | buffer: bytes}}

      :nomatch ->
        {:error, state}

      {offset, 1} when offset < @frame_limit ->
        <<line::binary-size(offset), _newline, rest::binary>> = bytes

        with {:ok, frame} <- Jason.decode(line),
             {:ok, state} <- receive_frame(frame, state) do
          consume(rest, state)
        else
          _ -> {:error, state}
        end

      _ ->
        {:error, state}
    end
  end

  defp receive_frame(%{"version" => 1, "id" => id} = frame, state) when is_binary(id) do
    case Map.get(state.pending, id) do
      nil when id == state.closing -> receive_reply(frame, %{kind: :close}, id, state)
      nil when state.phase in [:closing, :uncertain] -> {:ok, state}
      nil -> {:error, state}
      request -> receive_reply(frame, request, id, state)
    end
  end

  defp receive_frame(_, state), do: {:error, state}

  defp receive_reply(%{"result" => result} = frame, request, id, state)
       when is_map(result) and not is_map_key(frame, "error") do
    case result["generation"] do
      generation when is_integer(generation) and generation >= 0 ->
        state = %{state | generation: generation}

        case request.kind do
          :initialize ->
            phase = if state.phase == :initializing, do: :ready, else: state.phase
            {:ok, reply_request(%{state | phase: phase}, id, {:ok, result})}

          :close ->
            # Keep the close waiter until the actual helper exit is observed.
            {:ok, %{state | cleanup_confirmed: result["cleanup_confirmed"] === true}}

          _ ->
            {:ok, reply_request(state, id, {:ok, result})}
        end

      _ ->
        {:error, state}
    end
  end

  defp receive_reply(%{"error" => error} = frame, request, id, state)
       when is_map(error) and not is_map_key(frame, "result") do
    if is_binary(error["class"]) and is_binary(error["message"]) and
         is_boolean(error["dispatched"]) do
      case error["generation"] do
        generation when is_integer(generation) and generation >= 0 ->
          state = %{state | generation: generation}

          if request.kind == :close do
            {:ok, teardown_unconfirmed(state, "Browser helper could not confirm cleanup")}
          else
            {:ok, reply_request(state, id, {:error, error})}
          end

        _ ->
          if request.kind == :close do
            {:ok, teardown_unconfirmed(state, "Browser helper could not confirm cleanup")}
          else
            state = reply_request(state, id, {:error, error})
            {:ok, begin_close(state, nil)}
          end
      end
    else
      {:error, state}
    end
  end

  defp receive_reply(_, _, _, state), do: {:error, state}

  defp reply_request(state, id, reply) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        state

      {request, pending} ->
        Process.cancel_timer(request.timer)
        if request.monitor, do: Process.demonitor(request.monitor, [:flush])
        if request.from, do: GenServer.reply(request.from, reply)

        %{
          state
          | pending: pending,
            active: if(state.active == id, do: nil, else: state.active),
            cancel: if(state.cancel == id, do: nil, else: state.cancel)
        }
    end
  end

  defp begin_close(%{closing: id} = state, _from) when is_binary(id), do: state

  defp begin_close(%{port: port} = state, from) when is_port(port),
    do: request(state, :close, %{}, from, @cleanup_timeout)

  defp begin_close(state, _from), do: state

  defp transport_failed(%{closing: id} = state, message) when is_binary(id),
    do: teardown_unconfirmed(state, message)

  defp transport_failed(state, message) do
    state =
      Enum.reduce(Map.keys(state.pending), state, fn id, acc ->
        reply_request(acc, id, {:error, unknown(message)})
      end)

    begin_close(%{state | phase: :uncertain}, nil)
  end

  defp settle_exit(state) do
    if state.close_retry, do: Process.cancel_timer(state.close_retry)

    confirmed =
      state.cleanup_confirmed and state.exit_status == 0 and not state.transport_teardown

    state =
      Enum.reduce(state.pending, state, fn {id, request}, acc ->
        reply =
          if request.kind == :close and confirmed,
            do: :ok,
            else: {:error, unknown("Browser helper exited without a confirmed result")}

        reply_request(acc, id, reply)
      end)

    %{
      state
      | phase: if(confirmed, do: :closed, else: :uncertain),
        close_frame: nil,
        close_retry: nil,
        close_deadline: nil
    }
  end

  defp teardown_unconfirmed(state, message) do
    if state.close_retry, do: Process.cancel_timer(state.close_retry)

    state =
      Enum.reduce(Map.keys(state.pending), state, fn id, acc ->
        reply_request(acc, id, {:error, unknown(message)})
      end)

    # Closing the owned pipe delivers EOF to the helper's cleanup handler. This
    # is a final bounded attempt, never evidence that Node or Chromium exited.
    # Keep the opaque Port and close identity for inspection; no reuse is allowed.
    try do
      if state.port, do: Port.close(state.port)
    rescue
      ArgumentError -> :ok
    end

    %{
      state
      | phase: :uncertain,
        cleanup_confirmed: false,
        transport_teardown: true,
        close_frame: nil,
        close_retry: nil,
        close_deadline: nil
    }
  end

  defp unavailable(%{phase: :ready}), do: failure("busy", "A browser request is pending", false)
  defp unavailable(_state), do: failure("unavailable", "Browser resource is not ready", false)

  defp unknown(message), do: failure("unknown_outcome", message, true)

  defp failure(class, message, dispatched),
    do: %{"class" => class, "message" => message, "dispatched" => dispatched}
end
