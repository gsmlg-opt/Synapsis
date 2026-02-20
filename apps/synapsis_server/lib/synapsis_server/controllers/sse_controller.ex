defmodule SynapsisServer.SSEController do
  use SynapsisServer, :controller

  def events(conn, %{"id" => session_id}) do
    Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session_id}")

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    sse_loop(conn, session_id)
  end

  @event_pattern ~r/^[a-z0-9_-]+$/

  defp sse_loop(conn, session_id) do
    receive do
      {event, payload} when is_binary(event) ->
        if Regex.match?(@event_pattern, event) do
          data = Jason.encode!(payload)
          chunk_data = "event: #{event}\ndata: #{data}\n\n"

          case chunk(conn, chunk_data) do
            {:ok, conn} -> sse_loop(conn, session_id)
            {:error, _} -> conn
          end
        else
          # Skip events with invalid names to prevent SSE protocol injection
          sse_loop(conn, session_id)
        end

      _ ->
        sse_loop(conn, session_id)
    after
      30_000 ->
        case chunk(conn, ":keepalive\n\n") do
          {:ok, conn} -> sse_loop(conn, session_id)
          {:error, _} -> conn
        end
    end
  end
end
