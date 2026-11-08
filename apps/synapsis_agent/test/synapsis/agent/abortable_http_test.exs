defmodule Synapsis.Agent.TestSupport.AbortableHTTPTest do
  use ExUnit.Case, async: true

  alias Synapsis.Agent.TestSupport.AbortableHTTP

  test "peer closure completes the waiting callback without a failed response write" do
    {fixture, socket, handler} = waiting_handler()
    monitor = Process.monitor(handler)
    :ok = :gen_tcp.close(socket)

    assert_receive {:provider_disconnected, ^handler}, 1_000
    assert_receive {:handler_outcome, ^handler, :disconnected}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^handler, _}, 1_000
    assert :ok = Gaoxy.Test.verify!(fixture)
  end

  test "release preserves a writable streaming response" do
    {fixture, socket, handler} = waiting_handler()
    send(handler, :release)

    assert_receive {:handler_outcome, ^handler, :released}, 1_000
    assert {:ok, bytes} = :gen_tcp.recv(socket, 0, 1_000)
    assert bytes =~ "released"
    :ok = :gen_tcp.close(socket)
    assert :ok = Gaoxy.Test.verify!(fixture)
    refute_received {:provider_disconnected, _}
  end

  test "an elapsed wait remains a timeout rather than a disconnect" do
    {fixture, socket, handler} = waiting_handler(timeout: 200)
    assert_receive {:handler_outcome, ^handler, :timeout}, 1_000
    :ok = :gen_tcp.close(socket)
    assert :ok = Gaoxy.Test.verify!(fixture)
    refute_received {:provider_disconnected, _}
  end

  for reason <- [:fixture_failure, :shutdown] do
    @tag capture_log: true
    test "an unexpected #{reason} handler exit remains a fixture failure" do
      {fixture, socket, handler} = waiting_handler(mode: :manual)
      monitor = Process.monitor(handler)
      Process.exit(handler, unquote(reason))

      assert_receive {:DOWN, ^monitor, :process, ^handler, _reason}, 1_000
      refute_received {:provider_disconnected, _}
      assert catch_exit(Gaoxy.Test.verify!(fixture)) == unquote(reason)
      assert %{status: :error} = Gaoxy.Test.close(fixture)
      :ok = :gen_tcp.close(socket)
    end
  end

  @tag capture_log: true
  test "callback exceptions after a disconnect are still reported" do
    {fixture, socket, handler} = waiting_handler(mode: :manual, fail_after_wait: true)
    monitor = Process.monitor(handler)
    :ok = :gen_tcp.close(socket)

    assert_receive {:handler_outcome, ^handler, :disconnected}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^handler, _}, 1_000
    assert_raise RuntimeError, "callback failed after wait", fn -> Gaoxy.Test.verify!(fixture) end
    assert %{status: :error} = Gaoxy.Test.close(fixture)
  end

  defp waiting_handler(opts \\ []) do
    owner = self()
    fixture = Gaoxy.Test.open(mode: Keyword.get(opts, :mode, :auto))
    on_exit(fn -> Gaoxy.Test.close(fixture) end)

    Gaoxy.Test.expect_once(fixture, "GET", "/wait", fn conn ->
      send(owner, {:handler_ready, self()})

      {outcome, conn} =
        AbortableHTTP.await(conn, :release, Keyword.get(opts, :timeout, 2_000), owner)

      send(owner, {:handler_outcome, self(), outcome})
      if opts[:fail_after_wait], do: raise("callback failed after wait")

      if outcome == :released do
        {:ok, conn} = Plug.Conn.chunk(conn, "released")
        conn
      else
        conn
      end
    end)

    uri = URI.parse(Gaoxy.Test.url(fixture, "/wait"))
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", uri.port, [:binary, active: false], 1_000)
    :ok = :gen_tcp.send(socket, "GET /wait HTTP/1.1\r\nHost: localhost\r\n\r\n")
    assert_receive {:handler_ready, handler}, 1_000
    assert {:ok, headers} = :gen_tcp.recv(socket, 0, 1_000)
    assert headers =~ "HTTP/1.1 200"
    {fixture, socket, handler}
  end
end
