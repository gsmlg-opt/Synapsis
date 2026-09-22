defmodule Synapsis.Agent.TestSupport.AbortableHTTPTest do
  use ExUnit.Case, async: true

  alias Synapsis.Agent.TestSupport.AbortableHTTP

  test "recognizes only the owning connection's shutdown as a disconnect" do
    {_supervisor, task} = waiting_handler()
    Process.exit(task.pid, :shutdown)
    assert Task.await(task, 1_000) == :disconnected
    assert_receive {:provider_disconnected, pid}
    assert pid == task.pid
  end

  @tag capture_log: true
  test "an unexpected connection exit remains a failure" do
    {_supervisor, task} = waiting_handler()
    Process.exit(task.pid, :fixture_failure)
    assert Task.yield(task, 1_000) == {:exit, :fixture_failure}
    refute_received {:provider_disconnected, _pid}
  end

  test "shutdown from an unrelated process remains a failure" do
    {supervisor, task} = waiting_handler()

    {:ok, _sender} =
      Task.Supervisor.start_child(supervisor, fn -> Process.exit(task.pid, :shutdown) end)

    assert Task.yield(task, 1_000) == {:exit, :shutdown}
    refute_received {:provider_disconnected, _pid}
  end

  defp waiting_handler do
    owner = self()
    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        conn = %Plug.Conn{adapter: {Plug.Cowboy.Conn, %{pid: owner}}}
        conn = AbortableHTTP.arm(conn)
        send(owner, {:handler_ready, self()})
        AbortableHTTP.await(conn, :release, 2_000, owner)
      end)

    assert_receive {:handler_ready, pid}
    assert pid == task.pid
    {supervisor, task}
  end
end
