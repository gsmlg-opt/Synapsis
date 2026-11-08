defmodule Synapsis.SkillWorkshop.Contract do
  @moduledoc """
  One invocation's source-derived, pure workshop content contract.

  Core retains document, version, discovery and persistence ownership. The child
  receives inert JSON and exits after one response. Its evaluation thread keeps
  the child timeout responsive while the original synchronous parser runs.

  All I/O shares the caller's absolute deadline, capped at five seconds. A result
  is acknowledged only after the exact response, actual Node exit zero and Port
  release have been observed. Cleanup never substitutes for completion evidence.
  Errors are opaque; content and raw parser diagnostics are never returned.
  """

  @reference "488631c18fae7cc541ba8fc8beff6cbb0438787b"
  @frame_bytes 8 * 1024 * 1024
  @chunk_bytes 65_536
  @runtime_keys ~w(node v8 unicode icu cldr platform arch)

  @spec run(map(), integer()) :: {:ok, term(), map()} | {:error, atom()}
  def run(request, deadline) when is_map(request) and is_integer(deadline) do
    deadline = min(deadline, System.monotonic_time(:millisecond) + 5_000)

    with {:ok, body} <- encode(request),
         {:ok, node} <- node_executable(),
         {:ok, session} <- open(node, deadline) do
      try do
        with :ok <- write(session, body),
             {:ok, envelope, down?} <- response(session, [], 0, false),
             :ok <- close_and_confirm(session, down?) do
          {:ok, envelope["result"],
           %{
             reference_commit: @reference,
             exit_status: 0,
             os_pid: session.os_pid,
             closed: true,
             runtime: envelope["runtime"]
           }}
        end
      after
        release(session)
      end
    end
  rescue
    _ -> {:error, :content_contract}
  catch
    _, _ -> {:error, :content_contract}
  end

  def run(_, _), do: {:error, :content_contract}

  defp encode(request) do
    case Jason.encode(request) do
      {:ok, body} when byte_size(body) + 1 <= @frame_bytes -> {:ok, body <> "\n"}
      _ -> {:error, :content_contract}
    end
  end

  defp node_executable do
    configured =
      Application.get_env(:synapsis_agent, :filesystem_node) ||
        System.get_env("SYNAPSIS_FILESYSTEM_NODE") || "node"

    case configured do
      value when is_binary(value) ->
        case System.find_executable(value) do
          path when is_binary(path) -> {:ok, Path.expand(path)}
          _ -> {:error, :content_contract}
        end

      _ ->
        {:error, :content_contract}
    end
  end

  defp open(node, deadline) do
    if remaining(deadline) > 0 do
      helper = Application.app_dir(:synapsis_core, "priv/skill_workshop/worker.mjs")

      port =
        Port.open({:spawn_executable, String.to_charlist(node)}, [
          :binary,
          :exit_status,
          :use_stdio,
          :eof,
          {:line, @chunk_bytes},
          args: [
            String.to_charlist(helper),
            ~c"--timeout-ms",
            Integer.to_charlist(remaining(deadline))
          ]
        ])

      monitor = :erlang.monitor(:port, port)

      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} when is_integer(os_pid) and os_pid > 0 ->
          {:ok, %{port: port, monitor: monitor, deadline: deadline, os_pid: os_pid}}

        _ ->
          release(%{port: port, monitor: monitor})
          {:error, :content_contract}
      end
    else
      {:error, :timeout}
    end
  end

  defp write(session, body) do
    if remaining(session.deadline) <= 0 do
      {:error, :timeout}
    else
      if Port.command(session.port, body, [:nosuspend]) do
        :ok
      else
        receive do
        after
          min(5, remaining(session.deadline)) -> write(session, body)
        end
      end
    end
  end

  defp response(%{port: port, monitor: monitor} = session, chunks, bytes, down?) do
    receive do
      {^port, {:data, {kind, chunk}}} when kind in [:eol, :noeol] ->
        delimiter = if kind == :eol, do: "\n", else: ""
        size = bytes + byte_size(chunk) + byte_size(delimiter)

        if size <= @frame_bytes do
          response(session, [[chunk, delimiter] | chunks], size, down?)
        else
          {:error, :content_contract}
        end

      {^port, {:exit_status, 0}} ->
        with true <- remaining(session.deadline) > 0,
             [json, ""] <-
               chunks |> Enum.reverse() |> IO.iodata_to_binary() |> :binary.split("\n", [:global]),
             {:ok, envelope} <- Jason.decode(json),
             true <- valid_envelope?(envelope, session.os_pid) do
          {:ok, envelope, down?}
        else
          _ -> {:error, :content_contract}
        end

      {^port, {:exit_status, _}} ->
        {:error, :content_contract}

      {^port, :eof} ->
        response(session, chunks, bytes, down?)

      {:DOWN, ^monitor, :port, ^port, :normal} ->
        response(session, chunks, bytes, true)

      {:DOWN, ^monitor, :port, ^port, _} ->
        {:error, :content_contract}
    after
      remaining(session.deadline) -> {:error, :timeout}
    end
  end

  defp valid_envelope?(envelope, os_pid) when is_map(envelope) do
    runtime = envelope["runtime"]

    Map.keys(envelope) |> Enum.sort() == ~w(pid protocol referenceCommit result runtime) and
      envelope["protocol"] == 1 and envelope["referenceCommit"] == @reference and
      envelope["pid"] == os_pid and is_map(runtime) and
      Enum.sort(Map.keys(runtime)) == Enum.sort(@runtime_keys) and
      Enum.all?(Map.values(runtime), &(is_binary(&1) and byte_size(&1) > 0))
  end

  defp valid_envelope?(_, _), do: false

  defp close_and_confirm(session, down?) do
    if Port.info(session.port) != nil, do: Port.close(session.port)
    if down?, do: :ok, else: await_closed(session)
  end

  defp await_closed(%{port: port, monitor: monitor} = session) do
    receive do
      {:DOWN, ^monitor, :port, ^port, :normal} -> :ok
      {:DOWN, ^monitor, :port, ^port, _} -> {:error, :content_contract}
      {^port, :eof} -> await_closed(session)
    after
      remaining(session.deadline) -> {:error, :timeout}
    end
  end

  defp release(session) do
    close_if_open(session.port)
    :erlang.demonitor(session.monitor, [:flush])
    flush_port(session.port)
  end

  defp close_if_open(port) do
    if Port.info(port) != nil, do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp flush_port(port) do
    receive do
      {^port, _} -> flush_port(port)
      {:EXIT, ^port, _} -> flush_port(port)
    after
      0 -> :ok
    end
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
