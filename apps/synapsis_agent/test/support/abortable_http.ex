defmodule Synapsis.Agent.TestSupport.AbortableHTTP do
  @moduledoc """
  Bounded waits for HTTP streams whose clients are intentionally cancelled.

  Establish the response before waiting, then poll the public Gaoxy connection
  API. A peer disconnect completes the callback without another response write;
  unexpected socket errors, exits and callback exceptions remain failures.
  """

  def await(conn, release, timeout, owner) do
    conn =
      if conn.state == :chunked do
        conn
      else
        conn
        |> Gaoxy.HTTP.put_stream_timeout(timeout + 1_000)
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)
      end

    wait(conn, release, System.monotonic_time(:millisecond) + timeout, owner)
  end

  defp wait(conn, release, deadline, owner) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:timeout, conn}
    else
      case Gaoxy.HTTP.poll_connection(conn, 0) do
        {:pending, conn} ->
          receive do
            ^release -> {:released, conn}
            {:EXIT, _pid, reason} -> exit(reason)
          after
            min(remaining, 10) -> wait(conn, release, deadline, owner)
          end

        {:error, reason, conn} when reason in [:closed, :econnreset] ->
          send(owner, {:provider_disconnected, self()})
          {:disconnected, conn}

        {:error, reason, _conn} ->
          raise "unexpected HTTP stream poll failure: #{inspect(reason)}"

        {:more, _conn} ->
          raise "unexpected input while waiting for HTTP stream cancellation"
      end
    end
  end
end
