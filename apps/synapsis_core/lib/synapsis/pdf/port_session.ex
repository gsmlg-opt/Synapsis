defmodule Synapsis.PDF.PortSession do
  @moduledoc """
  Temporary, bytes-only broker for one PDF extraction in an owned Node process.

  `start_link/1` is dormant and requires trusted explicit Node/helper paths and an
  owner pid. The future supervised native effect calls `extract/4` only after
  registration. This module does not acquire files or register a native tool.

  Extraction returns `{:ok, result}` only after one complete JSON frame and an
  observed helper exit 0. Errors are `{:error, reason}`; `:unknown_outcome` means
  actual process exit was not observed. Cancellation can race completion, in
  which case exit 0 plus a valid result preserves the completed outcome. Deadline
  and owner/caller loss suppress late result publication. No operation is replayed.

  `cancel/1` and `close/1` return `{:ok, status}` after settlement and preserve an
  already completed outcome. `status/1` exposes lifecycle data, never PDF bytes or
  extraction results. Closing a Port is a fallback, never proof of OS cleanup.
  """
  use GenServer, restart: :temporary

  @max_bytes 10 * 1024 * 1024
  @input_limit 14_046_552
  @output_limit 56_162_764
  @cleanup_timeout 2_000
  @retry_interval 25
  @chunk_size 65_536

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @spec extract(pid(), binary(), map() | keyword(), pos_integer()) ::
          {:ok, map()} | {:error, atom()}
  def extract(pid, bytes, opts, timeout_ms),
    do:
      GenServer.call(
        pid,
        {:extract, bytes, opts, timeout_ms},
        timeout_ms + @cleanup_timeout + 1_000
      )

  def cancel(pid), do: GenServer.call(pid, :cancel, @cleanup_timeout + 1_000)
  def close(pid), do: GenServer.call(pid, :close, @cleanup_timeout + 1_000)
  def status(pid), do: GenServer.call(pid, :status)

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
         port: nil,
         os_pid: nil,
         phase: :dormant,
         outcome: nil,
         cleanup_confirmed: false,
         exit_status: nil,
         caller: nil,
         caller_monitor: nil,
         waiters: [],
         chunks: [],
         output_size: 0,
         frame_complete: false,
         deadline: nil,
         deadline_timer: nil,
         cleanup_timer: nil,
         retry_timer: nil,
         reason: nil,
         suppress_result: false,
         stop_after_cleanup: false
       }}
    else
      {:stop, :owner_unavailable}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, public_status(state), state}

  def handle_call({:extract, bytes, opts, timeout}, from, %{phase: :dormant} = state)
      when is_binary(bytes) and byte_size(bytes) in 1..@max_bytes and
             is_integer(timeout) and timeout in 1..120_000 do
    deadline = now() + timeout

    state = %{
      state
      | caller: from,
        caller_monitor: Process.monitor(elem(from, 0)),
        deadline: deadline,
        phase: :running
    }

    with {:ok, frame} <- request_frame(bytes, opts),
         true <- now() < deadline,
         {:ok, port, os_pid} <- open_port(state, max(1, deadline - now())) do
      state = %{
        state
        | port: port,
          os_pid: os_pid,
          deadline_timer: Process.send_after(self(), :deadline, max(0, deadline - now()))
      }

      case write(port, frame) do
        :ok -> {:noreply, state}
        _ -> {:noreply, begin_cancel(state, :transport_error)}
      end
    else
      false -> {:noreply, settle(state, :timeout, true)}
      {:error, reason} -> {:noreply, settle(state, reason, true)}
    end
  end

  def handle_call({:extract, _, _, _}, _from, state),
    do: {:reply, {:error, :unavailable}, state}

  def handle_call(action, _from, %{phase: :settled} = state) when action in [:cancel, :close],
    do: {:reply, {:ok, public_status(state)}, state}

  def handle_call(action, _from, %{phase: :dormant} = state) when action in [:cancel, :close] do
    state = settle(state, if(action == :cancel, do: :cancelled, else: :closed), true)
    {:reply, {:ok, public_status(state)}, state}
  end

  def handle_call(action, from, state) when action in [:cancel, :close] do
    state = %{state | waiters: [from | state.waiters]}
    {:noreply, begin_cancel(state, :cancelled)}
  end

  @impl true
  def handle_info({port, {:data, {kind, chunk}}}, %{port: port} = state)
      when kind in [:eol, :noeol] do
    size = state.output_size + byte_size(chunk) + if(kind == :eol, do: 1, else: 0)

    if state.frame_complete or size > @output_limit or byte_size(chunk) > @chunk_size do
      finish_or_stop(fallback(state))
    else
      {:noreply,
       %{state | chunks: [chunk | state.chunks], output_size: size, frame_complete: kind == :eol}}
    end
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    # OS exit is already observed. Release the BEAM Port retained by :eof;
    # closing this resource is not itself evidence of helper termination.
    close_port(port)
    state = %{state | port: nil, exit_status: code}

    state =
      if Process.alive?(state.owner),
        do: state,
        else: %{state | caller: nil, suppress_result: true, stop_after_cleanup: true}

    state =
      if code == 0 and state.frame_complete and not state.suppress_result and
           now() < state.deadline do
        case decode_result(state) do
          {:ok, result} ->
            cond do
              now() >= state.deadline ->
                settle(state, :timeout, true)

              not Process.alive?(state.owner) ->
                settle(%{state | caller: nil, stop_after_cleanup: true}, :cancelled, true)

              state.caller != nil and not Process.alive?(elem(state.caller, 0)) ->
                settle(%{state | caller: nil}, :cancelled, true)

              true ->
                settle(state, :completed, true, result)
            end

          :error ->
            settle(state, state.reason || :invalid_result, true)
        end
      else
        settle(
          state,
          state.reason || if(now() >= state.deadline, do: :timeout, else: :helper_failed),
          true
        )
      end

    finish_or_stop(state)
  end

  def handle_info(:deadline, %{phase: phase} = state) when phase in [:running, :cancelling],
    do: {:noreply, begin_cancel(%{state | suppress_result: true, reason: :timeout}, :timeout)}

  def handle_info(:retry_cancel, %{phase: :cancelling} = state),
    do: finish_or_stop(write_cancel(%{state | retry_timer: nil}))

  def handle_info(:cleanup_timeout, %{phase: :cancelling} = state),
    do: finish_or_stop(fallback(state))

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_monitor: ref} = state) do
    state = %{state | caller: nil, suppress_result: true, stop_after_cleanup: true}

    cond do
      state.phase == :dormant -> {:stop, :normal, state}
      state.phase == :settled -> finish_or_stop(state)
      true -> finish_or_stop(begin_cancel(state, :cancelled))
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{caller_monitor: ref} = state)
      when not is_nil(ref) do
    state = %{state | caller: nil, caller_monitor: nil, suppress_result: true}

    if state.phase == :settled,
      do: {:noreply, state},
      else: {:noreply, begin_cancel(state, :cancelled)}
  end

  # EOF/normal link notifications are not OS exit confirmation. Wait for the
  # separately requested exit_status; a finite cleanup timer bounds that wait.
  def handle_info({port, :eof}, %{port: port} = state), do: {:noreply, state}
  def handle_info({:EXIT, port, :normal}, %{port: port} = state), do: {:noreply, state}

  def handle_info({:EXIT, port, _reason}, %{port: port} = state),
    do: finish_or_stop(begin_cancel(state, :transport_error))

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close_port(state.port)
    :ok
  end

  defp request_frame(bytes, opts) do
    frame =
      opts
      |> Map.new()
      |> Map.drop([:pdfBase64, "pdfBase64"])
      |> Map.put("pdfBase64", Base.encode64(bytes))
      |> Jason.encode!()

    if byte_size(frame) <= @input_limit,
      do: {:ok, frame <> "\n"},
      else: {:error, :input_too_large}
  rescue
    _ -> {:error, :invalid_request}
  end

  defp open_port(state, timeout) do
    port =
      Port.open({:spawn_executable, String.to_charlist(state.node)}, [
        :binary,
        :exit_status,
        :use_stdio,
        :eof,
        {:line, @chunk_size},
        args: [
          String.to_charlist(state.helper),
          ~c"--port",
          String.to_charlist("--timeout-ms=#{timeout}")
        ]
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

  defp write(port, frame) do
    if Port.command(port, frame, [:nosuspend]), do: :ok, else: :busy
  rescue
    _ -> :closed
  end

  defp begin_cancel(%{phase: :cancelling} = state, _reason), do: state

  defp begin_cancel(state, reason) do
    state = %{
      state
      | phase: :cancelling,
        reason: state.reason || reason,
        cleanup_timer: Process.send_after(self(), :cleanup_timeout, @cleanup_timeout)
    }

    write_cancel(state)
  end

  defp write_cancel(state) do
    case write(state.port, "cancel\n") do
      :ok -> state
      :busy -> %{state | retry_timer: Process.send_after(self(), :retry_cancel, @retry_interval)}
      :closed -> fallback(state)
    end
  end

  defp fallback(state) do
    close_port(state.port)
    settle(%{state | port: nil}, :unknown_outcome, false)
  end

  defp decode_result(state) do
    case state.chunks |> Enum.reverse() |> IO.iodata_to_binary() |> Jason.decode() do
      {:ok, %{"text" => text, "images" => images, "metadata" => metadata} = result}
      when is_binary(text) and is_list(images) and is_map(metadata) ->
        {:ok, result}

      _ ->
        :error
    end
  end

  defp settle(state, outcome, confirmed, result \\ nil) do
    Enum.each([state.deadline_timer, state.cleanup_timer, state.retry_timer], fn
      nil -> :ok
      timer -> Process.cancel_timer(timer)
    end)

    if state.caller_monitor, do: Process.demonitor(state.caller_monitor, [:flush])

    if state.caller,
      do:
        GenServer.reply(
          state.caller,
          if(outcome == :completed, do: {:ok, result}, else: {:error, outcome})
        )

    state = %{
      state
      | phase: :settled,
        outcome: outcome,
        cleanup_confirmed: confirmed,
        caller: nil,
        caller_monitor: nil,
        chunks: [],
        output_size: 0,
        frame_complete: false,
        deadline_timer: nil,
        cleanup_timer: nil,
        retry_timer: nil
    }

    Enum.each(state.waiters, &GenServer.reply(&1, {:ok, public_status(state)}))
    %{state | waiters: []}
  end

  defp public_status(state),
    do: Map.take(state, [:phase, :outcome, :cleanup_confirmed, :exit_status, :os_pid])

  defp now, do: System.monotonic_time(:millisecond)

  defp finish_or_stop(
         %{phase: :settled, stop_after_cleanup: true, cleanup_confirmed: true} = state
       ),
       do: {:stop, :normal, state}

  defp finish_or_stop(state), do: {:noreply, state}
  defp close_port(nil), do: :ok

  defp close_port(port) do
    Port.close(port)
  rescue
    _ -> :ok
  end
end
