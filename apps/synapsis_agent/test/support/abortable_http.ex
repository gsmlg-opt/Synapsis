defmodule Synapsis.Agent.TestSupport.AbortableHTTP do
  @moduledoc """
  Bounded waits for Bypass handlers whose clients are intentionally cancelled.

  Cowboy shuts down the request process when the connection closes. Let that
  handler return to Bypass so it can record a completed invocation; do not hide
  exits from other processes, unexpected reasons, or callback exceptions.
  """

  def arm(%Plug.Conn{adapter: {Plug.Cowboy.Conn, %{pid: _connection}}} = conn) do
    # This process serves only this request and exits after the handler returns.
    Process.flag(:trap_exit, true)
    conn
  end

  def await(%Plug.Conn{adapter: {Plug.Cowboy.Conn, %{pid: connection}}}, release, timeout, owner) do
    receive do
      ^release ->
        :released

      {:EXIT, ^connection, :shutdown} ->
        send(owner, {:provider_disconnected, self()})
        :disconnected

      {:EXIT, _pid, reason} ->
        exit(reason)
    after
      timeout -> :timeout
    end
  end
end
