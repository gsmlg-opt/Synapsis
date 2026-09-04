defmodule SynapsisServer.AgentEventsControllerTest do
  use SynapsisServer.ConnCase, async: false

  alias SynapsisServer.SSEController

  defmodule ClosingStreamAdapter do
    def send_chunked(state, status, headers) do
      send(state.owner, {:sse_open, self()})
      {:ok, body, state} = Plug.Adapters.Test.Conn.send_chunked(state, status, headers)
      {:ok, body, Map.put(state, :chunk_count, 0)}
    end

    def chunk(state, body) do
      body = IO.iodata_to_binary(body)
      send(state.owner, {:sse_chunk, self(), body})
      chunk_count = state.chunk_count + 1

      if chunk_count >= state.close_after do
        {:error, :closed}
      else
        Plug.Adapters.Test.Conn.chunk(%{state | chunk_count: chunk_count}, body)
      end
    end
  end

  test "streams initial status and mapped daemon events until the client closes", %{conn: conn} do
    conn = closing_stream(conn, 2)
    request = Task.async(fn -> SSEController.agent_events(conn, %{}) end)

    assert_receive {:sse_open, request_pid}
    assert_receive {:sse_chunk, ^request_pid, initial_frame}
    assert {"daemon_status", %{"status" => %{"ready" => _ready}}} = decode_frame(initial_frame)

    Phoenix.PubSub.broadcast(
      Synapsis.PubSub,
      "agent:daemon",
      {:agent_daemon_event, %{event: "internal.unknown", ignored: true}}
    )

    refute_receive {:sse_chunk, ^request_pid, _unknown_frame}, 50

    Phoenix.PubSub.broadcast(
      Synapsis.PubSub,
      "agent:daemon",
      {:agent_daemon_event,
       %{event: "backplane.sync.failed", connection_id: "connection-1", status: "degraded"}}
    )

    assert_receive {:sse_chunk, ^request_pid, mapped_frame}

    assert {"backplane_sync_failed", %{"connection_id" => "connection-1", "status" => "degraded"}} =
             decode_frame(mapped_frame)

    assert %Plug.Conn{state: :chunked} = Task.await(request)
  end

  test "returns when the client closes during the initial frame", %{conn: conn} do
    conn = closing_stream(conn, 1)

    assert %Plug.Conn{state: :chunked} = SSEController.agent_events(conn, %{})
    assert_receive {:sse_chunk, _request_pid, initial_frame}
    assert {"daemon_status", %{"status" => _status}} = decode_frame(initial_frame)
  end

  test "the routed endpoint accepts the event-stream media type" do
    conn =
      build_conn(:get, "/api/agent/events")
      |> put_req_header("accept", "text/event-stream")
      |> closing_stream(1)

    conn = SynapsisServer.Router.call(conn, SynapsisServer.Router.init([]))

    assert %Plug.Conn{status: 200, state: :chunked} = conn
    assert_receive {:sse_chunk, _request_pid, initial_frame}
    assert {"daemon_status", %{"status" => _status}} = decode_frame(initial_frame)
  end

  defp closing_stream(%Plug.Conn{adapter: {Plug.Adapters.Test.Conn, state}} = conn, close_after) do
    state = Map.put(state, :close_after, close_after)
    %{conn | adapter: {ClosingStreamAdapter, state}}
  end

  defp decode_frame(frame) do
    [event_line, data_line] = String.split(frame, "\n", trim: true)
    "event: " <> event = event_line
    "data: " <> data = data_line
    {event, Jason.decode!(data)}
  end
end
