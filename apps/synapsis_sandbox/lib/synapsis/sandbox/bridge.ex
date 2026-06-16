defmodule Synapsis.Sandbox.Bridge do
  @moduledoc """
  JSON-RPC callback bridge for sandbox runtimes.

  The bridge owns one stdio Port. Host-initiated `eval/3` calls are sent to the
  sandbox as JSON-RPC requests, while sandbox-initiated requests are routed back
  through `Synapsis.Tool.Executor` so normal tool policy still applies.
  """
  use GenServer
  require Logger

  @max_line 1_048_576
  @default_eval_timeout_ms 30_000
  @default_reverse_timeout_ms 30_000

  defstruct [
    :port,
    :command,
    :args,
    :env,
    :context,
    :task_supervisor,
    :eval,
    :output_pid,
    line_limit: @max_line,
    line_buffer: "",
    request_id: 1,
    pending_tools: %{},
    reverse_timeout_ms: @default_reverse_timeout_ms
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  def eval(server, params, timeout_ms \\ @default_eval_timeout_ms)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    GenServer.call(server, {:eval, normalize_eval_params(params), timeout_ms}, timeout_ms + 1_000)
  end

  @impl true
  def init(opts) do
    command = Keyword.fetch!(opts, :command)
    args = opts |> Keyword.get(:args, []) |> Enum.map(&to_string/1)
    env = opts |> Keyword.get(:env, %{}) |> normalize_env()
    context = Keyword.get(opts, :context, %{})
    task_supervisor = Keyword.get(opts, :task_supervisor, default_task_supervisor(context))
    line_limit = Keyword.get(opts, :line_limit, @max_line)

    with {:ok, executable} <- resolve_executable(command) do
      port =
        Port.open({:spawn_executable, executable}, [
          :binary,
          :use_stdio,
          :exit_status,
          {:line, line_limit},
          args: args,
          env: env
        ])

      {:ok,
       %__MODULE__{
         port: port,
         command: command,
         args: args,
         env: env,
         context: context,
         task_supervisor: task_supervisor,
         output_pid: Keyword.get(opts, :output_pid),
         line_limit: line_limit,
         reverse_timeout_ms: Keyword.get(opts, :reverse_timeout_ms, @default_reverse_timeout_ms)
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:eval, _params, _timeout_ms}, _from, %{eval: eval} = state)
      when not is_nil(eval),
      do: {:reply, {:error, :busy}, state}

  def handle_call({:eval, _params, _timeout_ms}, _from, %{port: port} = state)
      when not is_port(port),
      do: {:reply, {:error, :not_running}, state}

  def handle_call({:eval, params, timeout_ms}, from, state) do
    id = state.request_id
    payload = %{"jsonrpc" => "2.0", "id" => id, "method" => "eval", "params" => params}

    case write_json(state.port, payload) do
      :ok ->
        timer_ref = Process.send_after(self(), {:eval_timeout, id}, timeout_ms)

        {:noreply,
         %{
           state
           | request_id: id + 1,
             eval: %{id: id, from: from, timer_ref: timer_ref}
         }}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({port, {:data, {:noeol, line}}}, %{port: port} = state) do
    buffer = state.line_buffer <> line

    if byte_size(buffer) > state.line_limit do
      # An over-limit line is a sandbox adapter protocol violation: fail the
      # in-flight eval and stop (the supervisor restarts a fresh runtime)
      # instead of accumulating or truncating silently.
      fail_eval(state, :line_overflow)
      shutdown_pending_tools(state)

      Logger.warning("sandbox_bridge_line_overflow",
        command: state.command,
        limit: state.line_limit
      )

      close_port(state.port)

      {:stop, :line_overflow,
       %{state | port: nil, eval: nil, pending_tools: %{}, line_buffer: ""}}
    else
      {:noreply, %{state | line_buffer: buffer}}
    end
  end

  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    line = state.line_buffer <> line
    {:noreply, %{handle_line(line, state) | line_buffer: ""}}
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) when is_binary(data) do
    {:noreply, handle_line(data, state)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    fail_eval(state, {:sandbox_exited, status})
    shutdown_pending_tools(state)
    Logger.info("sandbox_bridge_exited", command: state.command, status: status)
    reason = if status == 0, do: :normal, else: {:sandbox_exited, status}
    {:stop, reason, %{state | port: nil, eval: nil, pending_tools: %{}}}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.pending_tools, ref) do
      {nil, _pending_tools} ->
        {:noreply, state}

      {pending, pending_tools} ->
        Process.demonitor(ref, [:flush])
        cancel_timer(pending.timer_ref)
        write_tool_response(state.port, pending.rpc_id, result)
        {:noreply, %{state | pending_tools: pending_tools}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
    case Map.pop(state.pending_tools, ref) do
      {nil, _pending_tools} ->
        {:noreply, state}

      {pending, pending_tools} ->
        cancel_timer(pending.timer_ref)

        write_error(
          state.port,
          pending.rpc_id,
          -32_000,
          "Tool task failed: #{safe_reason(reason)}"
        )

        {:noreply, %{state | pending_tools: pending_tools}}
    end
  end

  def handle_info({:reverse_timeout, ref}, state) do
    case Map.pop(state.pending_tools, ref) do
      {nil, _pending_tools} ->
        {:noreply, state}

      {pending, pending_tools} ->
        Task.shutdown(pending.task, :brutal_kill)
        write_error(state.port, pending.rpc_id, -32_001, "Tool task timed out")
        {:noreply, %{state | pending_tools: pending_tools}}
    end
  end

  def handle_info({:eval_timeout, id}, %{eval: %{id: id}} = state) do
    fail_eval(state, :timeout)
    close_port(state.port)
    {:stop, :eval_timeout, %{state | port: nil, eval: nil}}
  end

  def handle_info({:eval_timeout, _id}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close_port(state.port)
    :ok
  end

  defp handle_line(line, state) do
    case JSON.decode(line) do
      {:ok, %{"id" => _id, "result" => _result} = response} ->
        handle_response(response, state)

      {:ok, %{"id" => _id, "error" => _error} = response} ->
        handle_response(response, state)

      {:ok, %{"id" => id, "method" => method} = request} when is_binary(method) ->
        start_reverse_request(state, id, method, Map.get(request, "params", %{}))

      {:ok, _other} ->
        emit_output(state, line)

      {:error, _reason} ->
        emit_output(state, line)
    end
  end

  defp handle_response(%{"id" => id, "result" => result}, %{eval: %{id: id} = eval} = state) do
    cancel_timer(eval.timer_ref)
    GenServer.reply(eval.from, {:ok, result})
    %{state | eval: nil}
  end

  defp handle_response(%{"id" => id, "error" => error}, %{eval: %{id: id} = eval} = state) do
    cancel_timer(eval.timer_ref)
    GenServer.reply(eval.from, {:error, json_rpc_error_message(error)})
    %{state | eval: nil}
  end

  defp handle_response(_response, state), do: state

  defp start_reverse_request(state, rpc_id, method, params) do
    params = if is_map(params), do: params, else: %{}

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        Synapsis.Tool.Executor.execute(method, params, state.context)
      end)

    timer_ref = Process.send_after(self(), {:reverse_timeout, task.ref}, state.reverse_timeout_ms)

    pending = %{
      rpc_id: rpc_id,
      task: task,
      timer_ref: timer_ref
    }

    %{state | pending_tools: Map.put(state.pending_tools, task.ref, pending)}
  rescue
    e ->
      write_error(state.port, rpc_id, -32_000, "Tool dispatch failed: #{Exception.message(e)}")
      state
  catch
    :exit, reason ->
      write_error(state.port, rpc_id, -32_000, "Tool dispatch failed: #{safe_reason(reason)}")
      state
  end

  defp write_tool_response(port, rpc_id, {:ok, result}),
    do: write_json(port, json_result(rpc_id, result))

  defp write_tool_response(port, rpc_id, {:error, reason}),
    do: write_error(port, rpc_id, -32_000, safe_reason(reason))

  defp write_tool_response(port, rpc_id, other),
    do: write_error(port, rpc_id, -32_000, "Unexpected tool result: #{safe_reason(other)}")

  defp write_error(port, rpc_id, code, message) do
    write_json(port, %{
      "jsonrpc" => "2.0",
      "id" => rpc_id,
      "error" => %{"code" => code, "message" => message}
    })
  end

  defp write_json(port, payload) when is_port(port) do
    data = JSON.encode!(payload) <> "\n"

    case Port.command(port, data) do
      true -> :ok
      false -> {:error, :port_closed}
    end
  rescue
    e in [ArgumentError, Protocol.UndefinedError] -> {:error, Exception.message(e)}
  end

  defp write_json(_port, _payload), do: {:error, :not_running}

  defp json_result(rpc_id, result) do
    %{"jsonrpc" => "2.0", "id" => rpc_id, "result" => result}
  end

  defp fail_eval(%{eval: nil}, _reason), do: :ok

  defp fail_eval(%{eval: eval}, reason) do
    cancel_timer(eval.timer_ref)
    GenServer.reply(eval.from, {:error, reason})
  end

  defp shutdown_pending_tools(state) do
    Enum.each(state.pending_tools, fn {_ref, pending} ->
      cancel_timer(pending.timer_ref)
      Task.shutdown(pending.task, :brutal_kill)
    end)
  end

  defp close_port(port) when is_port(port) do
    Port.close(port)
  rescue
    _e in [ArgumentError] -> :ok
  end

  defp close_port(_port), do: :ok

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(ref) do
    Process.cancel_timer(ref)
    :ok
  end

  defp emit_output(state, line) do
    if is_pid(state.output_pid), do: send(state.output_pid, {:sandbox_output, line})

    case context_session_id(state.context) do
      nil ->
        :ok

      session_id ->
        Phoenix.PubSub.broadcast(
          Synapsis.PubSub,
          "session:#{session_id}",
          {"sandbox_output", %{line: line}}
        )
    end

    state
  end

  defp context_session_id(context) when is_map(context),
    do: context[:session_id] || context["session_id"]

  defp context_session_id(_context), do: nil

  defp normalize_eval_params(params) when is_binary(params), do: %{"code" => params}
  defp normalize_eval_params(params) when is_map(params), do: params
  defp normalize_eval_params(params), do: %{"input" => params}

  defp resolve_executable(command) do
    command = to_string(command)

    cond do
      Path.type(command) == :absolute and File.exists?(command) ->
        {:ok, command}

      String.contains?(command, "/") and File.exists?(command) ->
        {:ok, Path.expand(command)}

      executable = System.find_executable(command) ->
        {:ok, executable}

      true ->
        {:error, {:no_binary, command}}
    end
  end

  defp normalize_env(env) when is_map(env) do
    Enum.map(env, fn {key, value} ->
      {String.to_charlist(to_string(key)), String.to_charlist(to_string(value))}
    end)
  end

  defp normalize_env(env) when is_list(env), do: env
  defp normalize_env(_env), do: []

  defp default_task_supervisor(context) do
    case context[:session_id] || context["session_id"] do
      session_id when is_binary(session_id) ->
        Synapsis.Session.Supervisor.task_supervisor_via(session_id)

      _ ->
        Synapsis.Tool.TaskSupervisor
    end
  end

  defp json_rpc_error_message(%{"message" => message}) when is_binary(message), do: message
  defp json_rpc_error_message(error), do: safe_reason(error)

  defp safe_reason(reason) when is_binary(reason), do: reason
  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(reason), do: inspect(reason, limit: 20, printable_limit: 500)
end
