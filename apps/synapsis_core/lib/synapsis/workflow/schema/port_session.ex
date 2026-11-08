defmodule Synapsis.Workflow.Schema.PortSession do
  @moduledoc """
  Dormant, temporary owner of one reusable schema/template compute Node helper.

  Trusted absolute Node/helper paths and an owner pid are required. One operation
  at a time includes startup and transport in its deadline. The same worker and
  actual Ajv cache survive successful operations and explicit Machine resumes.
  Input (8 MiB), output (64 KiB), worker heap (128 MiB) and retained-cache (256)
  limits are finite host resource boundaries, not schema-language restrictions.
  No operation is replayed and no cache is evicted or silently replaced.

  An operation receipt proves computation completion while the helper remains
  alive. Normal close requires both the worker-closed frame and observed Node
  exit 0. EOF, Port.close and link notifications do not prove OS cleanup; lost
  observation settles as unknown_outcome with cleanup_confirmed false. Owner
  and active caller loss terminate the session and suppress late publication.
  """
  use GenServer, restart: :temporary

  alias Synapsis.Workflow.Value

  @input_limit 8 * 1024 * 1024
  @output_limit 64 * 1024
  @chunk_size 65_536
  @cleanup_timeout 2_000
  @retry_interval 25
  @max_timeout 120_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def fulfill(pid, request, heap, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms in 1..@max_timeout do
    deadline = now() + timeout_ms

    GenServer.call(
      pid,
      {:fulfill, request, heap, deadline},
      timeout_ms + @cleanup_timeout + 1_000
    )
  catch
    # A lost broker/call receipt proves neither operation completion nor helper
    # cleanup. In particular, never return the call's request/heap in an error.
    :exit, _reason -> {:error, :unknown_outcome}
  end

  def fulfill(_pid, _request, _heap, _timeout_ms), do: {:error, :invalid_timeout}
  def status(pid), do: GenServer.call(pid, :status)
  def close(pid), do: GenServer.call(pid, :close, @cleanup_timeout + 1_000)
  def cancel(pid), do: GenServer.call(pid, :cancel, @cleanup_timeout + 1_000)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(opts, :owner_pid)
    node = Keyword.fetch!(opts, :node_executable)
    helper = Keyword.fetch!(opts, :helper_path)

    cond do
      not is_pid(owner) or not Process.alive?(owner) ->
        {:stop, :owner_unavailable}

      not absolute_path?(node) or not absolute_path?(helper) ->
        {:stop, :invalid_helper_paths}

      true ->
        {:ok,
         %{
           owner: owner,
           owner_monitor: Process.monitor(owner),
           node: node,
           helper: helper,
           port: nil,
           os_pid: nil,
           phase: :dormant,
           ready: false,
           cache_entries: 0,
           cleanup_confirmed: false,
           exit_status: nil,
           closed_frame: false,
           chunks: [],
           output_size: 0,
           pending: nil,
           sequence: 0,
           operation_timer: nil,
           cleanup_timer: nil,
           retry_timer: nil,
           control: nil,
           waiters: [],
           reason: nil,
           stop_after_cleanup: false
         }}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, public_status(state), state}

  def handle_call(
        {:fulfill, %{"id" => id, "kind" => kind} = request, heap, deadline},
        from,
        %{phase: phase} = state
      )
      when phase in [:dormant, :idle] and is_binary(id) and is_map(heap) and
             kind in [
               "compile_schema",
               "validate_response",
               "render_template",
               "decode_template_file",
               "decode_state_text",
               "state_key_path",
               "sort_items"
             ] do
    with {:ok, sort_count} <- expected_sort_count(request, heap),
         {:ok, body} <- request_body(request, heap),
         true <- now() < deadline do
      sequence = state.sequence + 1

      state = %{
        state
        | phase: :running,
          sequence: sequence,
          pending: %{
            from: from,
            monitor: Process.monitor(elem(from, 0)),
            id: id,
            kind: kind,
            sort_count: sort_count,
            deadline: deadline,
            body: body
          },
          operation_timer:
            Process.send_after(self(), {:deadline, sequence}, max(0, deadline - now()))
      }

      case ensure_port(state) do
        {:ok, state} ->
          {:noreply, if(state.ready, do: send_operation(state), else: state)}

        {:error, reason} ->
          {:noreply, settle(%{state | reason: reason}, true)}
      end
    else
      false -> {:reply, {:error, :timeout}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:fulfill, _, _, _}, _from, state),
    do: {:reply, {:error, :unavailable}, state}

  def handle_call(action, _from, %{phase: :dormant} = state) when action in [:close, :cancel] do
    state = settle(%{state | reason: :never_started}, true)
    {:reply, {:ok, public_status(state)}, state}
  end

  def handle_call(action, _from, %{phase: :settled} = state) when action in [:close, :cancel],
    do: {:reply, control_result(action, state), state}

  def handle_call(:close, _from, %{phase: :running} = state),
    do: {:reply, {:error, :busy}, state}

  def handle_call(action, from, state) when action in [:close, :cancel] do
    state = %{state | waiters: [{from, action} | state.waiters]}

    state =
      if action == :close,
        do: begin_close(state, nil, "{\"type\":\"close\"}\n"),
        else: begin_close(state, :cancelled, "{\"type\":\"cancel\"}\n")

    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, {kind, chunk}}}, %{port: port} = state)
      when kind in [:eol, :noeol] do
    size = state.output_size + byte_size(chunk)

    cond do
      size + 1 > @output_limit or byte_size(chunk) > @chunk_size ->
        {:noreply, begin_cancel(state, :output_limit)}

      kind == :noeol ->
        {:noreply, %{state | chunks: [chunk | state.chunks], output_size: size}}

      true ->
        frame = [chunk | state.chunks] |> Enum.reverse() |> IO.iodata_to_binary()
        state = %{state | chunks: [], output_size: 0}

        case Jason.decode(frame) do
          {:ok, decoded} -> {:noreply, consume_result(decoded, state)}
          _ -> {:noreply, begin_cancel(state, :invalid_result)}
        end
    end
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    close_port(port)

    state = %{
      state
      | port: nil,
        exit_status: code,
        reason:
          state.reason ||
            if(state.phase == :closing and state.closed_frame and code == 0,
              do: nil,
              else: :helper_failed
            )
    }

    finish(settle(state, true))
  end

  def handle_info({:deadline, sequence}, %{phase: :running, sequence: sequence} = state),
    do: {:noreply, begin_cancel(state, :timeout)}

  def handle_info(:retry_control, %{phase: :closing} = state),
    do: {:noreply, write_control(%{state | retry_timer: nil})}

  def handle_info(:cleanup_timeout, %{phase: :closing} = state) do
    close_port(state.port)
    finish(settle(%{state | port: nil, reason: :unknown_outcome}, false))
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_monitor: ref} = state) do
    state = suppress_pending(%{state | stop_after_cleanup: true})

    if state.phase in [:dormant, :settled],
      do: {:stop, :normal, state},
      else: {:noreply, begin_cancel(state, :owner_lost)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{pending: %{monitor: ref}} = state),
    do: {:noreply, state |> suppress_pending() |> begin_cancel(:caller_lost)}

  # These notifications are not OS exit proof. Retain the Port and await the
  # separately requested exit_status, bounded by cleanup_timeout.
  def handle_info({port, :eof}, %{port: port, phase: :closing} = state),
    do: {:noreply, state}

  def handle_info({port, :eof}, %{port: port} = state),
    do: {:noreply, begin_cancel(state, :transport_error)}

  def handle_info({:EXIT, port, :normal}, %{port: port} = state), do: {:noreply, state}

  def handle_info({:EXIT, port, _reason}, %{port: port} = state),
    do: {:noreply, begin_cancel(state, :transport_error)}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close_port(state.port)
    :ok
  end

  defp request_body(request, heap) do
    with {:ok, request_json} <- Jason.encode(request),
         {:ok, heap_json} <- Jason.encode(heap) do
      body = "\"request\":" <> request_json <> ",\"heap\":" <> heap_json <> "}"

      if byte_size(body) + 64 <= @input_limit,
        do: {:ok, body},
        else: {:error, :input_limit}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp expected_sort_count(
         %{"kind" => "sort_items", "keys" => %{"type" => "reference", "id" => id}},
         %{"version" => 1, "nodes" => nodes}
       )
       when is_map(nodes) do
    case nodes[id] do
      %{"type" => "array", "items" => items} when is_list(items) -> {:ok, length(items)}
      _ -> {:error, :invalid_request}
    end
  end

  defp expected_sort_count(%{"kind" => "sort_items"}, _heap),
    do: {:error, :invalid_request}

  defp expected_sort_count(_request, _heap), do: {:ok, nil}

  defp ensure_port(%{port: port} = state) when is_port(port), do: {:ok, state}

  defp ensure_port(state) do
    case open_port(state) do
      {:ok, port} ->
        # Keep the opened Port even if an immediate helper exit races this
        # optional status read; its exit_status is still required for cleanup.
        {:ok, %{state | port: port, os_pid: os_pid(port)}}

      error ->
        error
    end
  end

  defp open_port(state) do
    {:ok,
     Port.open({:spawn_executable, String.to_charlist(state.node)}, [
       :binary,
       :exit_status,
       :use_stdio,
       :eof,
       {:line, @chunk_size},
       args: [String.to_charlist(state.helper)]
     ])}
  rescue
    _ -> {:error, :helper_unavailable}
  end

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      nil -> nil
    end
  rescue
    _ -> nil
  end

  defp send_operation(%{pending: pending} = state) do
    remaining = pending.deadline - now()

    if remaining <= 0 do
      begin_cancel(state, :timeout)
    else
      # Literal trusted prefix: do not rely on Jason map key enumeration for the
      # main thread's bounded deadline header. The worker owns both JSON roots.
      frame =
        "{\"type\":\"request\",\"timeoutMs\":" <>
          Integer.to_string(remaining) <> "," <> pending.body <> "\n"

      case write(state.port, frame) do
        :ok -> %{state | pending: %{pending | body: nil}}
        _ -> begin_cancel(state, :transport_error)
      end
    end
  end

  defp consume_result(
         %{"type" => "ready", "version" => 1, "profile" => "ajv-8.20.0-draft07"},
         %{ready: false, phase: :running} = state
       ),
       do: send_operation(%{state | ready: true})

  defp consume_result(
         %{"type" => "result", "id" => id, "cacheEntries" => entries} = result,
         %{phase: :running, pending: %{id: id} = pending} = state
       )
       when is_integer(entries) and entries in 0..256 do
    cond do
      now() >= pending.deadline ->
        begin_cancel(state, :timeout)

      not Process.alive?(state.owner) ->
        begin_cancel(suppress_pending(%{state | stop_after_cleanup: true}), :owner_lost)

      not Process.alive?(elem(pending.from, 0)) ->
        begin_cancel(suppress_pending(state), :caller_lost)

      pending.kind in [
        "render_template",
        "decode_template_file",
        "decode_state_text",
        "state_key_path",
        "sort_items"
      ] and
          entries != state.cache_entries ->
        begin_cancel(state, :invalid_result)

      valid_operation_result?(result, pending) ->
        reply = if result["result"] == "ok", do: {:ok, result}, else: {:error, result}
        GenServer.reply(pending.from, reply)
        clear_pending(%{state | phase: :idle, cache_entries: entries})

      pending.kind in ["compile_schema", "validate_response"] and
        result["result"] == "error" and result["outcome"] == "resource_limit" ->
        begin_cancel(%{state | cache_entries: entries}, :resource_limit)

      true ->
        begin_cancel(state, :invalid_result)
    end
  end

  defp consume_result(%{"type" => "closed"}, %{phase: :closing, reason: nil} = state),
    do: %{state | closed_frame: true}

  defp consume_result(_result, %{phase: :closing} = state), do: state
  defp consume_result(_result, state), do: begin_cancel(state, :invalid_result)

  defp valid_operation_result?(
         %{"result" => "ok", "outcome" => "sorted", "indices" => indices} = result,
         %{kind: "sort_items", sort_count: count}
       ) do
    map_size(result) == 6 and is_list(indices) and length(indices) == count and
      Enum.all?(indices, &(is_integer(&1) and &1 >= 0 and &1 < count)) and
      MapSet.size(MapSet.new(indices)) == count
  end

  defp valid_operation_result?(result, %{kind: kind}),
    do: valid_operation_result?(result, kind)

  defp valid_operation_result?(%{"result" => "ok", "outcome" => "compiled"}, "compile_schema"),
    do: true

  defp valid_operation_result?(%{"result" => "ok", "outcome" => "valid"}, "validate_response"),
    do: true

  defp valid_operation_result?(
         %{"result" => "ok", "outcome" => "decoded", "value" => value} = result,
         kind
       )
       when kind in ["decode_template_file", "decode_state_text"],
       do: map_size(result) == 6 and canonical_string?(value)

  defp valid_operation_result?(
         %{"result" => "ok", "outcome" => "state_path", "lexical_path" => path} = result,
         "state_key_path"
       ),
       do: map_size(result) == 6 and is_binary(path) and String.valid?(path)

  defp valid_operation_result?(
         %{"result" => "ok", "outcome" => "rendered", "value" => value} = result,
         "render_template"
       ),
       do: map_size(result) == 6 and canonical_string?(value)

  defp valid_operation_result?(%{"result" => "error", "outcome" => "invalid_request"}, _kind),
    do: true

  defp valid_operation_result?(
         %{"result" => "error", "outcome" => "template_failed"},
         "render_template"
       ),
       do: true

  defp valid_operation_result?(%{"result" => "error", "outcome" => outcome}, kind)
       when kind in ["compile_schema", "validate_response"],
       do: outcome in ["invalid_schema", "invalid_response", "validation_failed"]

  defp valid_operation_result?(
         %{"result" => "unevaluated", "outcome" => "async_unevaluated"},
         "validate_response"
       ),
       do: true

  defp valid_operation_result?(_, _), do: false

  defp canonical_string?(%{"type" => "string", "value" => string} = value)
       when map_size(value) == 2 and is_binary(string),
       do: String.valid?(string)

  defp canonical_string?(%{"type" => "string", "utf16le" => encoded} = value)
       when map_size(value) == 2 and is_binary(encoded) do
    with {:ok, raw} <- Base.decode64(encoded),
         true <- Base.encode64(raw) == encoded and rem(byte_size(raw), 2) == 0 do
      Value.from_utf16le(raw) == value
    else
      _ -> false
    end
  end

  defp canonical_string?(_), do: false

  defp begin_cancel(state, reason),
    do: begin_close(state, reason, "{\"type\":\"cancel\"}\n")

  defp begin_close(%{phase: :closing} = state, reason, control) do
    if reason && is_nil(state.reason) do
      cancel_timer(state.retry_timer)
      write_control(%{state | reason: reason, control: control, retry_timer: nil})
    else
      state
    end
  end

  defp begin_close(state, reason, control) do
    cancel_timer(state.operation_timer)

    write_control(%{
      state
      | phase: :closing,
        reason: reason,
        control: control,
        operation_timer: nil,
        cleanup_timer: Process.send_after(self(), :cleanup_timeout, @cleanup_timeout)
    })
  end

  defp write_control(state) do
    case write(state.port, state.control) do
      :busy -> %{state | retry_timer: Process.send_after(self(), :retry_control, @retry_interval)}
      _ -> state
    end
  end

  defp write(port, frame) do
    if Port.command(port, frame, [:nosuspend]), do: :ok, else: :busy
  rescue
    _ -> :closed
  end

  defp suppress_pending(%{pending: nil} = state), do: state

  defp suppress_pending(state),
    do: %{state | pending: %{state.pending | from: nil}}

  defp clear_pending(state) do
    cancel_timer(state.operation_timer)
    if state.pending, do: Process.demonitor(state.pending.monitor, [:flush])
    %{state | pending: nil, operation_timer: nil}
  end

  defp settle(state, confirmed) do
    cancel_timer(state.cleanup_timer)
    cancel_timer(state.retry_timer)

    if state.pending && state.pending.from,
      do: GenServer.reply(state.pending.from, {:error, state.reason || :helper_failed})

    state =
      clear_pending(%{
        state
        | phase: :settled,
          cleanup_confirmed: confirmed,
          cleanup_timer: nil,
          retry_timer: nil,
          chunks: [],
          output_size: 0,
          control: nil
      })

    for {from, action} <- state.waiters,
        do: GenServer.reply(from, control_result(action, state))

    %{state | waiters: []}
  end

  defp control_result(
         :close,
         %{cleanup_confirmed: true, closed_frame: true, exit_status: 0} = state
       ),
       do: {:ok, public_status(state)}

  defp control_result(_action, %{reason: :never_started} = state),
    do: {:ok, public_status(state)}

  defp control_result(:cancel, %{cleanup_confirmed: true} = state),
    do: {:ok, public_status(state)}

  defp control_result(_action, state), do: {:error, state.reason || :unconfirmed_close}

  defp public_status(state),
    do:
      Map.take(state, [
        :phase,
        :os_pid,
        :cache_entries,
        :cleanup_confirmed,
        :exit_status,
        :reason
      ])

  defp finish(%{phase: :settled, stop_after_cleanup: true} = state),
    do: {:stop, :normal, state}

  defp finish(state), do: {:noreply, state}
  defp absolute_path?(path), do: is_binary(path) and Path.type(path) == :absolute
  defp now, do: System.monotonic_time(:millisecond)
  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)
  defp close_port(nil), do: :ok

  defp close_port(port) do
    Port.close(port)
  rescue
    _ -> :ok
  end
end
