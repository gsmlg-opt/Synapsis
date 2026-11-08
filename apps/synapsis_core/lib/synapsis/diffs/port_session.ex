defmodule Synapsis.Diffs.PortSession do
  @moduledoc """
  Dormant owner of one internal, explicitly configured Diffs rendering capsule.

  One operation includes helper startup, real SSR, hydration and completed files
  in its deadline. Requests are never replayed. Receipts describe files under the
  supplied staging root; they do not publish a viewer, apply TTL, or persist a
  session. Input is bounded at 8 MiB and metadata at 64 KiB; each artifact is
  bounded at 32 MiB. The helper owns its SSR worker and Chromium process.

  Normal close requires a worker-closed frame, the captured Chromium exit event,
  and independently observed Node Port exit 0. EOF or Port.close alone cannot
  confirm cleanup. Owner/caller loss suppresses late receipts.
  """
  use GenServer, restart: :temporary

  @input_limit 8 * 1024 * 1024
  @metadata_limit 64 * 1024
  @cleanup_timeout 11_000
  @reference "488631c18fae7cc541ba8fc8beff6cbb0438787b"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def render(pid, plan, timeout_ms) when is_integer(timeout_ms) and timeout_ms in 1..120_000 do
    GenServer.call(
      pid,
      {:render, plan, now() + timeout_ms},
      timeout_ms + @cleanup_timeout + 1_000
    )
  catch
    :exit, _ -> {:error, :unknown_outcome}
  end

  def render(_, _, _), do: {:error, :invalid_timeout}
  def status(pid), do: GenServer.call(pid, :status)
  def close(pid), do: GenServer.call(pid, :close, @cleanup_timeout + 1_000)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(opts, :owner_pid)

    paths =
      Map.new(
        [:node_executable, :helper_path, :chromium_executable, :staging_root],
        &{&1, Keyword.fetch!(opts, &1)}
      )

    if is_pid(owner) and Process.alive?(owner) and
         Enum.all?(paths, fn {_, path} -> is_binary(path) and Path.type(path) == :absolute end) do
      {:ok,
       Map.merge(paths, %{
         owner: owner,
         owner_monitor: Process.monitor(owner),
         phase: :dormant,
         port: nil,
         os_pid: nil,
         browser_pid: nil,
         sequence: 0,
         ready: nil,
         pending: nil,
         timer: nil,
         cleanup_timer: nil,
         retry_timer: nil,
         chunks: [],
         size: 0,
         waiters: [],
         reason: nil,
         exit_status: nil,
         worker_closed: false,
         browser_exit: nil,
         closed_frame: false,
         cleanup_confirmed: false,
         stop_after_cleanup: false
       })}
    else
      {:stop, :invalid_owner_or_paths}
    end
  end

  @impl true
  def handle_call(:status, _, state), do: {:reply, public_status(state), state}

  def handle_call({:render, plan, deadline}, from, %{phase: phase} = state)
      when phase in [:dormant, :idle] do
    with %{
           "input" => %{},
           "options" => %{"languagePackAvailable" => false},
           "renderTarget" => target
         } <- plan,
         true <- target in ~w(viewer image both),
         {:ok, body} <- Jason.encode(plan),
         true <- byte_size(body) + 128 <= @input_limit and now() < deadline do
      sequence = state.sequence + 1

      pending = %{
        from: from,
        monitor: Process.monitor(elem(from, 0)),
        deadline: deadline,
        body: body,
        target: target,
        format: get_in(plan, ["options", "image", "format"])
      }

      state = %{
        state
        | phase: :running,
          pending: pending,
          sequence: sequence,
          timer: Process.send_after(self(), {:deadline, sequence}, max(0, deadline - now()))
      }

      case ensure_port(state) do
        {:ok, state} -> {:noreply, if(state.ready, do: send_request(state), else: state)}
        {:error, state} -> {:noreply, settle(%{state | reason: :helper_unavailable})}
      end
    else
      _ -> {:reply, {:error, :invalid_request}, state}
    end
  end

  def handle_call({:render, _, _}, _, state), do: {:reply, {:error, :unavailable}, state}

  def handle_call(:close, _, %{phase: :dormant} = state),
    do:
      {:reply, {:ok, public_status(%{state | phase: :settled, cleanup_confirmed: true})},
       %{state | phase: :settled, cleanup_confirmed: true}}

  def handle_call(:close, _, %{phase: :settled} = state), do: {:reply, close_result(state), state}
  def handle_call(:close, _, %{phase: :running} = state), do: {:reply, {:error, :busy}, state}

  def handle_call(:close, from, state) do
    {:noreply, begin_close(%{state | waiters: [from | state.waiters]}, nil)}
  end

  @impl true
  def handle_info({port, {:data, {kind, bytes}}}, %{port: port} = state)
      when kind in [:eol, :noeol] do
    size = state.size + byte_size(bytes)

    if size + 1 > @metadata_limit do
      {:noreply, begin_close(state, :invalid_result)}
    else
      if kind == :noeol do
        {:noreply, %{state | chunks: [bytes | state.chunks], size: size}}
      else
        raw = [bytes | state.chunks] |> Enum.reverse() |> IO.iodata_to_binary()
        state = %{state | chunks: [], size: 0}

        case Jason.decode(raw) do
          {:ok, frame} -> {:noreply, consume(frame, state)}
          _ -> {:noreply, begin_close(state, :invalid_result)}
        end
      end
    end
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    close_port(port)
    confirmed = state.phase == :closing and state.closed_frame and code == 0

    state =
      settle(%{
        state
        | port: nil,
          exit_status: code,
          cleanup_confirmed: confirmed,
          reason: state.reason || if(confirmed, do: nil, else: :unconfirmed_close)
      })

    finish(state)
  end

  def handle_info({:deadline, id}, %{phase: :running, sequence: id} = state),
    do: {:noreply, begin_close(state, :timeout)}

  def handle_info(:cleanup_timeout, %{phase: :closing} = state) do
    close_port(state.port)
    finish(settle(%{state | port: nil, reason: :unknown_outcome, cleanup_confirmed: false}))
  end

  def handle_info(:retry_close, %{phase: :closing} = state), do: {:noreply, write_close(state)}

  def handle_info({:DOWN, ref, :process, _, _}, %{owner_monitor: ref} = state) do
    state = suppress(%{state | stop_after_cleanup: true})

    if state.phase in [:dormant, :settled],
      do: {:stop, :normal, state},
      else: {:noreply, begin_close(state, :owner_lost)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{pending: %{monitor: ref}} = state),
    do: {:noreply, begin_close(suppress(state), :caller_lost)}

  def handle_info({port, :eof}, %{port: port, phase: :closing} = state), do: {:noreply, state}

  def handle_info({port, :eof}, %{port: port} = state),
    do: {:noreply, begin_close(state, :transport_error)}

  def handle_info({:EXIT, port, :normal}, %{port: port} = state), do: {:noreply, state}

  def handle_info({:EXIT, port, _}, %{port: port} = state),
    do: {:noreply, begin_close(state, :transport_error)}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state), do: close_port(state.port)

  defp ensure_port(%{port: port} = state) when is_port(port), do: {:ok, state}

  defp ensure_port(state) do
    port =
      Port.open({:spawn_executable, String.to_charlist(state.node_executable)}, [
        :binary,
        :exit_status,
        :use_stdio,
        :eof,
        {:line, @metadata_limit},
        cd: String.to_charlist(Path.dirname(state.helper_path)),
        args:
          Enum.map(
            [
              state.helper_path,
              "--chromium",
              state.chromium_executable,
              "--staging",
              state.staging_root
            ],
            &String.to_charlist/1
          )
      ])

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        nil -> nil
      end

    {:ok, %{state | port: port, os_pid: os_pid}}
  rescue
    _ -> {:error, state}
  end

  defp send_request(state) do
    remaining = state.pending.deadline - now()

    frame =
      "{\"type\":\"request\",\"timeoutMs\":#{max(1, remaining)},\"id\":#{state.sequence},\"plan\":" <>
        state.pending.body <> "}\n"

    if remaining > 0 and write(state.port, frame) == :ok,
      do: %{state | pending: %{state.pending | body: nil}},
      else: begin_close(state, :transport_error)
  end

  defp consume(
         %{
           "type" => "ready",
           "version" => 1,
           "reference" => @reference,
           "languagePackAvailable" => false,
           "packages" => packages,
           "assets" => assets
         } = ready,
         %{ready: nil, phase: :running} = state
       )
       when is_map(packages) and is_map(assets) do
    expected = %{
      "node_modules/@pierre/diffs" => {"@pierre/diffs", "1.5.2"},
      "node_modules/playwright-core" => {"playwright-core", "1.64.0"},
      "packages/tool-host/node_modules/shiki" => {"shiki", "4.5.0"}
    }

    valid =
      Enum.all?(expected, fn {path, {name, version}} ->
        packages[path] == %{"name" => name, "version" => version}
      end)

    if valid and match?(%{"sha256" => _}, assets["viewer-runtime.js"]),
      do: send_request(%{state | ready: ready}),
      else: begin_close(state, :invalid_result)
  end

  defp consume(
         %{"type" => "result", "receipt" => %{"id" => id} = receipt, "browserPid" => browser},
         %{phase: :running, sequence: id, pending: pending} = state
       ) do
    if ((now() < pending.deadline and Process.alive?(state.owner) and pending.from) &&
          Process.alive?(elem(pending.from, 0))) and valid_receipt?(receipt, pending) and
         (is_nil(browser) or (is_integer(browser) and browser > 0)) and
         (is_nil(state.browser_pid) or state.browser_pid == browser) do
      GenServer.reply(pending.from, {:ok, receipt})
      clear_pending(%{state | phase: :idle, browser_pid: browser})
    else
      begin_close(state, :invalid_result)
    end
  end

  defp consume(
         %{"type" => "closed", "workerClosed" => true, "browserExit" => exit},
         %{phase: :closing} = state
       ) do
    valid =
      if state.browser_pid,
        do: exit == %{"pid" => state.browser_pid, "code" => 0, "signal" => nil},
        else: is_nil(exit)

    if valid,
      do: %{state | closed_frame: true, worker_closed: true, browser_exit: exit},
      else: %{state | reason: state.reason || :unconfirmed_close}
  end

  defp consume(_, %{phase: :closing} = state), do: state
  defp consume(_, state), do: begin_close(state, :invalid_result)

  defp valid_receipt?(
         %{
           "version" => 1,
           "title" => title,
           "inputKind" => kind,
           "fileCount" => count,
           "artifacts" => artifacts
         },
         pending
       )
       when is_binary(title) and kind in ~w(before_after patch) and is_integer(count) and
              count > 0 and is_map(artifacts) do
    expected =
      case pending.target do
        "viewer" -> ["html"]
        "image" -> ["file", "imageHtml"]
        "both" -> ["file", "html", "imageHtml"]
      end

    Enum.sort(Map.keys(artifacts)) == expected and
      Enum.all?(artifacts, fn {key, item} ->
        mime =
          if key == "file",
            do: if(pending.format == "pdf", do: "application/pdf", else: "image/png"),
            else: "text/html; charset=utf-8"

        case item do
          %{"path" => path, "mimeType" => ^mime, "bytes" => size, "sha256" => hash}
          when is_binary(path) and is_integer(size) and size > 0 and size <= 32 * 1024 * 1024 and
                 is_binary(hash) ->
            Path.type(path) == :relative and Enum.all?(Path.split(path), &(&1 not in ["..", "."])) and
              Regex.match?(~r/\A[0-9a-f]{64}\z/, hash)

          _ ->
            false
        end
      end)
  end

  defp valid_receipt?(_, _), do: false

  defp begin_close(%{phase: :settled} = state, _), do: state

  defp begin_close(%{phase: :closing} = state, reason),
    do: %{state | reason: state.reason || reason}

  defp begin_close(state, reason) do
    cancel_timer(state.timer)

    state = %{
      state
      | phase: :closing,
        reason: state.reason || reason,
        timer: nil,
        cleanup_timer: Process.send_after(self(), :cleanup_timeout, @cleanup_timeout)
    }

    write_close(state)
  end

  defp write_close(state) do
    case write(state.port, "{\"type\":\"close\"}\n") do
      :busy -> %{state | retry_timer: Process.send_after(self(), :retry_close, 25)}
      _ -> state
    end
  end

  defp write(port, frame) do
    if Port.command(port, frame, [:nosuspend]), do: :ok, else: :busy
  rescue
    _ -> :closed
  end

  defp suppress(%{pending: nil} = state), do: state
  defp suppress(state), do: %{state | pending: %{state.pending | from: nil}}

  defp clear_pending(state) do
    cancel_timer(state.timer)
    if state.pending, do: Process.demonitor(state.pending.monitor, [:flush])
    %{state | pending: nil, timer: nil}
  end

  defp settle(state) do
    for timer <- [state.cleanup_timer, state.retry_timer], do: cancel_timer(timer)

    if state.pending && state.pending.from,
      do: GenServer.reply(state.pending.from, {:error, state.reason || :helper_failed})

    state =
      clear_pending(%{
        state
        | phase: :settled,
          cleanup_timer: nil,
          retry_timer: nil,
          chunks: [],
          size: 0
      })

    for from <- state.waiters, do: GenServer.reply(from, close_result(state))
    %{state | waiters: []}
  end

  defp close_result(%{cleanup_confirmed: true, reason: nil} = state),
    do: {:ok, public_status(state)}

  defp close_result(state), do: {:error, state.reason || :unconfirmed_close}

  defp public_status(state),
    do:
      Map.take(state, [
        :phase,
        :os_pid,
        :browser_pid,
        :sequence,
        :ready,
        :cleanup_confirmed,
        :exit_status,
        :worker_closed,
        :browser_exit,
        :reason
      ])

  defp finish(%{stop_after_cleanup: true} = state), do: {:stop, :normal, state}
  defp finish(state), do: {:noreply, state}
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
