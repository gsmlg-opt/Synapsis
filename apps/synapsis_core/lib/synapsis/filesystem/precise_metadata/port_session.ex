defmodule Synapsis.Filesystem.PreciseMetadata.PortSession do
  @moduledoc """
  Dormant invocation broker for precise, read-only filesystem metadata.

  The participating Filesystem guardian registers this broker before it opens
  Node. Actual Node exit and Port release precede completion; owner/caller loss
  uses the same cancellation and unknown-cleanup discipline as Local's brokers.
  This module is separate from the pure content planner and owns no writes.
  """
  use GenServer, restart: :temporary

  @operation_timeout 5_000
  @cleanup_timeout 2_000
  @input_limit 8 * 1024 * 1024
  @output_limit 8 * 1024 * 1024
  @chunk_size 65_536
  @retry_interval 10
  @runtime_fields ~w(node v8 unicode icu cldr platform arch)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def capture(pid, request, deadline) do
    remaining = if is_integer(deadline), do: max(0, deadline - now()), else: 0

    GenServer.call(
      pid,
      {:capture, request, deadline},
      min(remaining, @operation_timeout) + @cleanup_timeout + 1_000
    )
  end

  def status(pid), do: GenServer.call(pid, :status)

  def close(pid),
    do: GenServer.call(pid, :close, @operation_timeout + @cleanup_timeout + 1_000)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(opts, :owner_pid)
    caller = Keyword.fetch!(opts, :caller_pid)
    node = Keyword.fetch!(opts, :node_executable)
    helper = Keyword.fetch!(opts, :helper_path)
    observer = Keyword.get(opts, :observer_pid)
    notification = Keyword.get(opts, :notification)

    if live?(owner) and live?(caller) and absolute?(node) and absolute?(helper) and
         (is_nil(observer) or is_pid(observer)) and valid_notification?(notification, owner) do
      {:ok,
       %{
         owner: owner,
         owner_monitor: Process.monitor(owner),
         caller: caller,
         caller_monitor: Process.monitor(caller),
         node: node,
         helper: helper,
         observer: observer,
         notification: notification,
         port: nil,
         os_pid: nil,
         port_released: true,
         phase: :dormant,
         outcome: nil,
         cleanup_confirmed: false,
         exit_status: nil,
         deadline: nil,
         deadline_timer: nil,
         cleanup_timer: nil,
         retry_timer: nil,
         request: nil,
         input: nil,
         input_offset: 0,
         chunks: [],
         output_size: 0,
         frame_complete: false,
         reason: nil,
         capture_from: nil,
         close_waiters: [],
         retire: false,
         cancel_sent: false
       }}
    else
      {:stop, :invalid_options}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, public_status(state), state}

  def handle_call({:capture, request, deadline}, {caller, _} = from, %{phase: :dormant} = state)
      when caller == state.caller do
    remaining = if is_integer(deadline), do: deadline - now(), else: 0

    cond do
      remaining <= 0 or remaining > @operation_timeout ->
        {:reply, {:error, :invalid_deadline}, state}

      not live?(state.owner) or not live?(state.caller) ->
        finish(settle(%{state | retire: true, capture_from: from}, :cancelled, true))

      true ->
        state = %{state | deadline: deadline, capture_from: from, phase: :running}

        with {:ok, frame} <- request_frame(request),
             true <- now() < deadline,
             {:owners_alive, true} <- {:owners_alive, live?(state.owner) and live?(state.caller)},
             {:ok, port, os_pid} <- open_port(state, deadline - now()) do
          state = %{
            state
            | port: port,
              os_pid: os_pid,
              port_released: false,
              request: request,
              input: frame,
              deadline_timer: Process.send_after(self(), :deadline, max(0, deadline - now()))
          }

          send(self(), :write_request)
          {:noreply, state}
        else
          false -> finish(settle(state, :timeout, true))
          {:owners_alive, false} -> finish(settle(%{state | retire: true}, :cancelled, true))
          {:error, reason} -> finish(settle(state, reason, true))
        end
    end
  end

  def handle_call({:capture, _, _}, _from, state),
    do: {:reply, {:error, :unavailable}, state}

  def handle_call(:close, _from, %{phase: :settled} = state),
    do: {:stop, :normal, {:ok, public_status(state)}, state}

  def handle_call(:close, _from, %{phase: :dormant} = state) do
    state = settle(state, :closed, true)
    {:stop, :normal, {:ok, public_status(state)}, state}
  end

  def handle_call(:close, from, state) do
    state = %{state | retire: true, close_waiters: [from | state.close_waiters]}
    finish(begin_cancel(state, :cancelled))
  end

  @impl true
  def handle_info(:write_request, %{phase: :running} = state) do
    state = %{state | retry_timer: nil}

    cond do
      now() >= state.deadline ->
        finish(begin_cancel(state, :timeout))

      not live?(state.owner) or not live?(state.caller) ->
        finish(begin_cancel(%{state | retire: true}, :cancelled))

      true ->
        length = min(@chunk_size, byte_size(state.input) - state.input_offset)
        chunk = binary_part(state.input, state.input_offset, length)

        case write(state.port, chunk) do
          :ok ->
            offset = state.input_offset + length

            if offset == byte_size(state.input) do
              {:noreply, %{state | input: nil, input_offset: 0}}
            else
              send(self(), :write_request)
              {:noreply, %{state | input_offset: offset}}
            end

          :busy ->
            {:noreply, retry(state, :write_request)}

          :closed ->
            finish(begin_cancel(state, :transport_error))
        end
    end
  end

  def handle_info({port, {:data, {kind, chunk}}}, %{port: port, phase: phase} = state)
      when kind in [:eol, :noeol] and phase in [:running, :cancelling] do
    size = state.output_size + byte_size(chunk) + if(kind == :eol, do: 1, else: 0)

    if state.frame_complete or size > @output_limit or byte_size(chunk) > @chunk_size do
      finish(begin_cancel(state, :invalid_result))
    else
      {:noreply,
       %{state | chunks: [chunk | state.chunks], output_size: size, frame_complete: kind == :eol}}
    end
  end

  def handle_info({port, {:exit_status, code}}, %{port: port, phase: phase} = state)
      when phase in [:running, :cancelling] do
    state = %{release_port(state) | exit_status: code}

    state =
      cond do
        not state.port_released ->
          settle(state, :unknown_outcome, false)

        not live?(state.owner) or not live?(state.caller) ->
          settle(%{state | retire: true}, :cancelled, true)

        now() >= state.deadline ->
          settle(state, :timeout, true)

        state.reason != nil ->
          settle(state, state.reason, true)

        code != 0 ->
          settle(state, :helper_failed, true)

        not is_integer(state.os_pid) or state.os_pid <= 0 ->
          settle(state, :invalid_result, true)

        not state.frame_complete ->
          settle(state, :invalid_result, true)

        true ->
          complete(state)
      end

    finish(state)
  end

  def handle_info(:deadline, %{phase: phase} = state) when phase in [:running, :cancelling],
    do: finish(begin_cancel(state, :timeout))

  def handle_info(:retry_cancel, %{phase: :cancelling} = state),
    do: finish(write_cancel(%{state | retry_timer: nil}))

  def handle_info(:cleanup_timeout, %{phase: :cancelling} = state),
    do: finish(settle(release_port(state), :unknown_outcome, false))

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state)
      when monitor == state.owner_monitor or monitor == state.caller_monitor do
    state = %{state | retire: true}

    case state.phase do
      :dormant -> finish(settle(state, :cancelled, true))
      :settled -> finish(state)
      _ -> finish(begin_cancel(state, :cancelled))
    end
  end

  # Neither EOF nor a link notification proves that the OS process exited.
  def handle_info({port, :eof}, %{port: port} = state), do: {:noreply, state}
  def handle_info({:EXIT, port, :normal}, %{port: port} = state), do: {:noreply, state}

  def handle_info({:EXIT, port, _reason}, %{port: port, phase: phase} = state)
      when phase in [:running, :cancelling],
      do: finish(begin_cancel(state, :transport_error))

  # Monitors above own guardian/caller loss. Trapping links lets cleanup finish
  # even when the worker that started this broker exits first.
  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    release_port(state)
    :ok
  end

  defp request_frame(request) do
    if valid_request?(request) do
      case Jason.encode(request) do
        {:ok, bytes} when byte_size(bytes) <= @input_limit -> {:ok, bytes <> "\n"}
        {:ok, _} -> {:error, :input_too_large}
        {:error, _} -> {:error, :invalid_request}
      end
    else
      {:error, :invalid_request}
    end
  end

  defp valid_request?(%{"root" => root, "files" => files} = request) do
    allowed_keys?(request, ~w(root files names)) and absolute?(root) and
      Path.expand(root) == root and is_list(files) and Enum.all?(files, &relative_file?/1) and
      is_list(Map.get(request, "names", [])) and
      Enum.all?(Map.get(request, "names", []), &text?/1)
  end

  defp valid_request?(_), do: false

  defp relative_file?(path),
    do:
      text?(path) and Path.type(path) == :relative and
        not String.contains?(path, ["\\", "\0"]) and
        Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))

  defp text?(text),
    do: is_binary(text) and String.valid?(text) and not String.contains?(text, "\0")

  defp open_port(state, remaining) when remaining > 0 and remaining <= @operation_timeout do
    port =
      Port.open({:spawn_executable, String.to_charlist(state.node)}, [
        :binary,
        :exit_status,
        :use_stdio,
        :eof,
        {:line, @chunk_size},
        args: [String.to_charlist(state.helper), String.to_charlist("--timeout-ms=#{remaining}")]
      ])

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        nil -> nil
      end

    {:ok, port, os_pid}
  rescue
    _ -> {:error, :helper_unavailable}
  end

  defp open_port(_, _), do: {:error, :timeout}

  defp write(port, bytes) do
    if Port.command(port, bytes, [:nosuspend]), do: :ok, else: :busy
  rescue
    _ -> :closed
  end

  defp retry(state, message) do
    delay = min(@retry_interval, max(0, state.deadline - now()))
    %{state | retry_timer: Process.send_after(self(), message, delay)}
  end

  defp begin_cancel(%{phase: :cancelling} = state, reason) do
    if reason == :timeout, do: %{state | reason: :timeout}, else: state
  end

  defp begin_cancel(state, reason) do
    cancel_timer(state.retry_timer)
    cleanup_deadline = min(now(), state.deadline) + @cleanup_timeout

    state = %{
      state
      | phase: :cancelling,
        reason: reason,
        input: nil,
        input_offset: 0,
        retry_timer: nil,
        cleanup_timer:
          Process.send_after(self(), :cleanup_timeout, max(0, cleanup_deadline - now()))
    }

    write_cancel(state)
  end

  defp write_cancel(%{cancel_sent: true} = state), do: state

  defp write_cancel(state) do
    case write(state.port, "cancel\n") do
      :ok -> %{state | cancel_sent: true}
      :busy -> %{state | retry_timer: Process.send_after(self(), :retry_cancel, @retry_interval)}
      :closed -> state
    end
  end

  defp complete(state) do
    decoded = state.chunks |> Enum.reverse() |> IO.iodata_to_binary() |> Jason.decode()

    case decoded do
      {:ok, envelope} ->
        cond do
          not valid_envelope?(envelope, state) ->
            settle(state, :invalid_result, true)

          now() >= state.deadline ->
            settle(state, :timeout, true)

          not live?(state.owner) or not live?(state.caller) ->
            settle(%{state | retire: true}, :cancelled, true)

          true ->
            settle(state, :completed, true, envelope)
        end

      _ ->
        settle(state, :invalid_result, true)
    end
  end

  defp valid_envelope?(
         %{"protocol" => 1, "pid" => pid, "runtime" => runtime, "result" => result} = envelope,
         state
       ) do
    exact_keys?(envelope, ~w(protocol pid runtime result)) and pid == state.os_pid and
      is_map(runtime) and exact_keys?(runtime, @runtime_fields) and
      Enum.all?(@runtime_fields, &(is_binary(runtime[&1]) and byte_size(runtime[&1]) > 0)) and
      valid_result?(result, state.request)
  end

  defp valid_envelope?(_, _), do: false

  defp valid_result?(
         %{"files" => files, "sizeBytes" => bytes, "updatedAtMs" => time, "names" => names} =
           result,
         request
       ) do
    exact_keys?(result, ~w(files sizeBytes updatedAtMs names)) and is_list(files) and
      Enum.all?(files, &relative_file?/1) and Enum.sort(files) == Enum.sort(request["files"]) and
      is_integer(bytes) and bytes >= 0 and is_integer(time) and time >= 0 and
      is_list(names) and Enum.all?(names, &text?/1) and
      Enum.sort(names) == Enum.sort(Map.get(request, "names", []))
  end

  defp valid_result?(_, _), do: false

  defp settle(state, outcome, confirmed, result \\ nil)
  defp settle(%{phase: :settled} = state, _, _, _), do: state

  defp settle(state, outcome, confirmed, result) do
    Enum.each([state.deadline_timer, state.cleanup_timer, state.retry_timer], &cancel_timer/1)

    state = %{
      state
      | phase: :settled,
        outcome: outcome,
        cleanup_confirmed: confirmed,
        input: nil,
        input_offset: 0,
        chunks: [],
        output_size: 0,
        frame_complete: false,
        deadline_timer: nil,
        cleanup_timer: nil,
        retry_timer: nil
    }

    status = public_status(state)
    if state.observer, do: send(state.observer, {:filesystem_metadata, self(), status})

    if state.notification do
      {owner, ref} = state.notification
      send(owner, {ref, :planner_settled, self(), status})
    end

    if state.capture_from do
      reply = if outcome == :completed, do: {:ok, result}, else: {:error, outcome}
      GenServer.reply(state.capture_from, reply)
    end

    Enum.each(state.close_waiters, &GenServer.reply(&1, {:ok, status}))
    %{state | capture_from: nil, close_waiters: []}
  end

  defp public_status(state),
    do:
      Map.take(state, [
        :phase,
        :outcome,
        :cleanup_confirmed,
        :exit_status,
        :os_pid,
        :port,
        :port_released
      ])

  defp finish(%{phase: :settled, retire: true} = state), do: {:stop, :normal, state}
  defp finish(state), do: {:noreply, state}

  defp release_port(%{port: nil} = state), do: %{state | port_released: true}

  defp release_port(state) do
    close_port(state.port)
    %{state | port_released: Port.info(state.port) == nil}
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    _ -> :ok
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp exact_keys?(value, keys),
    do: map_size(value) == length(keys) and allowed_keys?(value, keys)

  defp allowed_keys?(value, keys), do: Enum.all?(Map.keys(value), &(&1 in keys))
  defp absolute?(path), do: is_binary(path) and Path.type(path) == :absolute
  defp live?(pid), do: is_pid(pid) and Process.alive?(pid)
  defp valid_notification?(nil, _owner), do: true
  defp valid_notification?({owner, ref}, owner), do: is_reference(ref)
  defp valid_notification?(_, _owner), do: false
  defp now, do: System.monotonic_time(:millisecond)
end
