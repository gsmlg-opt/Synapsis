defmodule Synapsis.Agent.Tools.NativePtyFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Command
  alias Backplane.AgentRuntime.Tools.LocalCommand
  alias Synapsis.Agent.Tools.NativeLocal

  @moduletag :tmp_dir

  test "NativeLocal advertises the real 24 by 80 terminal and retains explicit pipe execution", %{
    tmp_dir: root
  } do
    runtime = open_runtime!()
    assert runtime.command.adapter == LocalCommand
    assert runtime.command.server == runtime.server
    assert {:ok, %{rows: 24, columns: 80}} = Command.terminal(runtime.command)
    assert {:ok, ^runtime} = NativeLocal.open(["exec_command", "write_stdin"], runtime)

    invocation =
      invocation(root, "[[ -p /dev/stdin && -p /dev/stdout ]] && printf 'pipe-ok\\n'", false)

    assert :ok = Command.reserve(runtime.command, invocation)
    assert {:ok, job} = Command.start(runtime.command, invocation)
    result = await_completed(runtime.command, invocation, job, deadline())
    assert result.output == ["pipe-ok"]
    assert result.exit_status == 0
    assert result.cleanup_status == :confirmed
    assert :ok = Command.acknowledge_release(runtime.command, invocation)
  end

  test "stopping the native backend cleans its actual PTY helper, command and descendant", %{
    tmp_dir: root
  } do
    runtime = open_runtime!()
    assert {:ok, terminal} = Command.terminal(runtime.command)

    script = """
    printf '%s' "$$" > command.pid
    #{System.find_executable("sleep")} 30 &
    printf '%s' "$!" > descendant.pid
    printf ready > process.ready
    wait
    """

    invocation = Map.put(invocation(root, script, true), :terminal, terminal)
    assert :ok = Command.reserve(runtime.command, invocation)
    assert {:ok, _job} = Command.start(runtime.command, invocation)
    await(fn -> File.read(Path.join(root, "process.ready")) == {:ok, "ready"} end, deadline())

    command = identity!(read_pid(root, "command.pid"))
    descendant = identity!(read_pid(root, "descendant.pid"))
    guardian = identity!(command.parent)
    broker = identity!(guardian.parent)

    for helper <- [guardian, broker] do
      assert File.read_link!("/proc/#{helper.pid}/exe") =~ "backplane-local-command-pty"
    end

    assert descendant.parent == command.pid
    assert :ok = GenServer.stop(runtime.server, :normal, 5_000)

    await(fn -> Enum.all?([command, descendant, guardian, broker], &exited?/1) end, deadline())
    refute Process.alive?(runtime.server)
  end

  defp open_runtime! do
    assert {:ok, runtime} = NativeLocal.open(["exec_command", "write_stdin"], nil)
    Process.unlink(runtime.server)

    on_exit(fn ->
      if Process.alive?(runtime.server), do: GenServer.stop(runtime.server, :normal, 5_000)
    end)

    runtime
  end

  defp invocation(root, script, tty) do
    %{
      executable: "/bin/bash",
      arguments: ["-c", script],
      workspace: root,
      environment: %{},
      owner_run_id: Ecto.UUID.generate(),
      owner_pid: self(),
      incarnation: 1,
      session_id: System.unique_integer([:positive, :monotonic]),
      tty: tty
    }
  end

  defp await_completed(command, invocation, job, deadline) do
    assert {:ok, result} = Command.read(command, invocation, job, cursor: 0)

    if result.status == :completed do
      result
    else
      assert System.monotonic_time(:millisecond) < deadline, inspect(result)
      Process.sleep(10)
      await_completed(command, invocation, job, deadline)
    end
  end

  defp read_pid(root, name), do: root |> Path.join(name) |> File.read!() |> String.to_integer()

  defp identity!(pid) do
    [_comm, fields] = File.read!("/proc/#{pid}/stat") |> String.split(") ", parts: 2)
    fields = String.split(fields)
    %{pid: pid, parent: String.to_integer(Enum.at(fields, 1)), start: Enum.at(fields, 19)}
  end

  defp exited?(identity) do
    case File.read("/proc/#{identity.pid}/stat") do
      {:error, :enoent} ->
        true

      {:ok, stat} ->
        [_comm, fields] = String.split(stat, ") ", parts: 2)
        fields = String.split(fields)
        Enum.at(fields, 19) != identity.start or hd(fields) in ["Z", "X"]

      _ ->
        false
    end
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 5_000

  defp await(check, deadline) do
    unless check.() do
      assert System.monotonic_time(:millisecond) < deadline, "PTY lifecycle observation timed out"
      Process.sleep(10)
      await(check, deadline)
    end
  end
end
