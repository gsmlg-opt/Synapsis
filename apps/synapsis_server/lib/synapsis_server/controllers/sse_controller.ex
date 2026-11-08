defmodule SynapsisServer.SSEController do
  use SynapsisServer, :controller

  alias Synapsis.Agent.Daemon
  alias SynapsisServer.AgentDaemonEvent

  @daemon_topic "agent:daemon"
  @keepalive_interval 30_000
  @connection_poll_interval 1_000

  def agent_events(conn, _params) do
    Phoenix.PubSub.subscribe(Synapsis.PubSub, @daemon_topic)

    conn =
      conn
      |> put_stream_timeout()
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    case send_agent_event(conn, "daemon_status", %{status: Daemon.status()}) do
      {:ok, conn} -> agent_event_loop(conn)
      {:error, conn} -> conn
    end
  end

  def events(conn, %{"id" => session_id}) do
    case Synapsis.Sessions.get(session_id) do
      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "Session not found"})

      {:ok, _session} ->
        Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{session_id}")

        conn =
          conn
          |> put_stream_timeout()
          |> put_resp_content_type("text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> put_resp_header("connection", "keep-alive")
          |> send_chunked(200)

        # ADR-006 B2: first frame is the current state from the live read
        # authority (process snapshot, or Concord fallback), then live deltas.
        case send_initial_state(conn, session_id) do
          {:ok, conn} -> sse_loop(conn, session_id)
          {:error, conn} -> conn
        end
    end
  end

  @event_pattern ~r/^[a-z0-9_-]+$/

  defp send_initial_state(conn, session_id) do
    payload =
      case Synapsis.Session.Read.live_snapshot(session_id) do
        {:live, %{status: status, in_flight_text: text} = snapshot} ->
          payload = %{live: true, status: to_string(status), in_flight: text}

          case Map.get(snapshot, :reply_presentation) do
            nil -> payload
            view -> Map.put(payload, :reply_presentation, view)
          end

        {:durable, %{meta: meta}} ->
          %{live: false, status: meta[:status], durable_turn_count: meta[:turn_count]}

        _ ->
          %{live: false, status: nil}
      end

    case Jason.encode(payload) do
      {:ok, data} ->
        case chunk(conn, "event: session_state\ndata: #{data}\n\n") do
          {:ok, conn} -> {:ok, conn}
          {:error, _} -> {:error, conn}
        end

      {:error, _} ->
        {:error, conn}
    end
  end

  defp sse_loop(conn, session_id, keepalive_at \\ next_keepalive()) do
    case stream_tick(conn, keepalive_at) do
      {:error, conn} ->
        conn

      {:ok, conn, keepalive_at} ->
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
                  sse_loop(conn, session_id, keepalive_at)
              end
            else
              # Skip events with invalid names to prevent SSE protocol injection
              sse_loop(conn, session_id, keepalive_at)
            end

          _ ->
            sse_loop(conn, session_id, keepalive_at)
        after
          @connection_poll_interval -> sse_loop(conn, session_id, keepalive_at)
        end
    end
  end

  defp agent_event_loop(conn, keepalive_at \\ next_keepalive()) do
    case stream_tick(conn, keepalive_at) do
      {:error, conn} ->
        conn

      {:ok, conn, keepalive_at} ->
        receive do
          message ->
            case AgentDaemonEvent.map(message) do
              {:ok, {event, payload}} ->
                case send_agent_event(conn, event, payload) do
                  {:ok, conn} -> agent_event_loop(conn)
                  {:error, conn} -> conn
                end

              :ignore ->
                agent_event_loop(conn, keepalive_at)
            end
        after
          @connection_poll_interval -> agent_event_loop(conn, keepalive_at)
        end
    end
  end

  defp put_stream_timeout(%Plug.Conn{adapter: {Gaoxy.PlugAdapter, _}} = conn),
    do: Gaoxy.HTTP.put_stream_timeout(conn, :infinity)

  # Plug test adapters have no transport deadline to extend or peer to poll.
  defp put_stream_timeout(conn), do: conn

  defp stream_tick(%Plug.Conn{adapter: {Gaoxy.PlugAdapter, _}} = conn, keepalive_at) do
    case Gaoxy.HTTP.poll_connection(conn, 0) do
      {:pending, conn} -> keepalive(conn, keepalive_at)
      {:more, conn} -> {:error, conn}
      {:error, _reason, conn} -> {:error, conn}
    end
  end

  defp stream_tick(conn, keepalive_at), do: keepalive(conn, keepalive_at)

  defp keepalive(conn, keepalive_at) do
    if System.monotonic_time(:millisecond) >= keepalive_at do
      case chunk(conn, ":keepalive\n\n") do
        {:ok, conn} -> {:ok, conn, next_keepalive()}
        {:error, _reason} -> {:error, conn}
      end
    else
      {:ok, conn, keepalive_at}
    end
  end

  defp next_keepalive, do: System.monotonic_time(:millisecond) + @keepalive_interval

  defp send_agent_event(conn, event, payload) do
    case Jason.encode(payload) do
      {:ok, data} ->
        case chunk(conn, "event: #{event}\ndata: #{data}\n\n") do
          {:ok, conn} -> {:ok, conn}
          {:error, _reason} -> {:error, conn}
        end

      {:error, _reason} ->
        {:ok, conn}
    end
  end
end
