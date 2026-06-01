defmodule SynapsisServer.SSEController do
  use SynapsisServer, :controller

  def events(conn, %{"id" => session_id}) do
    case Synapsis.Sessions.get(session_id) do
      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "Session not found"})

      {:ok, _session} ->
        Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session_id}")

        conn =
          conn
          |> put_resp_content_type("text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> put_resp_header("connection", "keep-alive")
          |> send_chunked(200)

        # ADR-006 B2: first frame is the current state from the live read
        # authority (process snapshot, or Concord fallback), then live deltas.
        conn
        |> send_initial_state(session_id)
        |> sse_loop(session_id)
    end
  end

  @event_pattern ~r/^[a-z0-9_-]+$/

  defp send_initial_state(conn, session_id) do
    payload =
      case Synapsis.Session.Read.live_snapshot(session_id) do
        {:live, %{status: status, in_flight_text: text}} ->
          %{live: true, status: to_string(status), in_flight: text}

        {:durable, %{meta: meta}} ->
          %{live: false, status: meta[:status], durable_turn_count: meta[:turn_count]}

        _ ->
          %{live: false, status: nil}
      end

    case Jason.encode(payload) do
      {:ok, data} ->
        case chunk(conn, "event: session_state\ndata: #{data}\n\n") do
          {:ok, conn} -> conn
          {:error, _} -> conn
        end

      {:error, _} ->
        conn
    end
  end

  defp sse_loop(conn, session_id) do
    receive do
      {event, payload} when is_binary(event) ->
        if Regex.match?(@event_pattern, event) do
          case Jason.encode(payload) do
            {:ok, data} ->
              chunk_data = "event: #{event}\ndata: #{data}\n\n"

              case chunk(conn, chunk_data) do
                {:ok, conn} -> sse_loop(conn, session_id)
                {:error, _} -> conn
              end

            {:error, _} ->
              # Skip events that cannot be serialized
              sse_loop(conn, session_id)
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
