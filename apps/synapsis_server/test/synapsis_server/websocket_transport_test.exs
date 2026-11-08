defmodule SynapsisServer.WebSocketTransportTest do
  use ExUnit.Case, async: false

  @timeout 5_000
  @payload_bytes 300 * 1_024

  # Exercise the wire transport independently of sessions and provider calls.
  # WebSockAdapter supplies the same frame ceiling used by Phoenix sockets.
  defmodule ProbePlug do
    @behaviour Plug

    @impl Plug
    def init(options), do: options

    @impl Plug
    def call(conn, _options) do
      conn
      |> WebSockAdapter.upgrade(SynapsisServer.WebSocketTransportTest.ProbeSocket, nil, [])
      |> Plug.Conn.halt()
    end
  end

  defmodule ProbeSocket do
    @behaviour WebSock

    @impl WebSock
    def init(state), do: {:ok, state}

    @impl WebSock
    def handle_in({"large", opcode: :text}, state) do
      {:push, {:text, String.duplicate("x", 300 * 1_024)}, state}
    end

    def handle_in({text, opcode: :text}, state), do: {:push, {:text, text}, state}

    @impl WebSock
    def handle_info(_message, state), do: {:ok, state}
  end

  test "endpoint HTTP budget permits large WebSocket replies and subsequent traffic" do
    options =
      SynapsisServer.Endpoint.config(:http)
      |> Keyword.merge(id: __MODULE__, plug: {ProbePlug, []}, ip: {127, 0, 0, 1}, port: 0)

    listener = start_supervised!({Gaoxy.HTTP, options})
    %{local: {:ok, {_address, port}}} = Gaoxy.info(listener, __MODULE__)

    assert {:ok, conn} =
             Mint.HTTP.connect(:http, "127.0.0.1", port,
               mode: :passive,
               protocols: [:http1],
               transport_opts: [timeout: @timeout]
             )

    # Closing the underlying socket also covers assertion failures below.
    socket = Mint.HTTP.get_socket(conn)
    on_exit(fn -> :gen_tcp.close(socket) end)

    assert {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/", [])
    {conn, status, headers} = receive_upgrade(conn, ref, deadline(), nil, [])
    assert status == 101
    assert {:ok, conn, websocket} = Mint.WebSocket.new(conn, ref, status, headers, mode: :passive)

    {conn, websocket} = send_frame(conn, websocket, ref, {:text, "large"})
    {conn, websocket, frame} = receive_frame(conn, websocket, ref, deadline())

    assert elem(frame, 0) == :text,
           "expected a large text reply, received #{frame_summary(frame)}"

    payload = elem(frame, 1)
    assert byte_size(payload) == @payload_bytes

    assert :crypto.hash(:sha256, payload) ==
             :crypto.hash(:sha256, String.duplicate("x", @payload_bytes))

    {conn, websocket} = send_frame(conn, websocket, ref, {:ping, "heartbeat"})
    {conn, websocket, frame} = receive_frame(conn, websocket, ref, deadline())
    assert frame == {:pong, "heartbeat"}

    {conn, websocket} = send_frame(conn, websocket, ref, {:text, "still-connected"})
    {_conn, _websocket, frame} = receive_frame(conn, websocket, ref, deadline())
    assert frame == {:text, "still-connected"}
  end

  defp receive_upgrade(conn, ref, deadline, status, headers) do
    assert {:ok, conn, responses} = Mint.WebSocket.recv(conn, 0, remaining(deadline))

    status =
      Enum.find_value(responses, status, fn
        {:status, ^ref, value} -> value
        _ -> nil
      end)

    headers =
      Enum.reduce(responses, headers, fn
        {:headers, ^ref, value}, acc -> acc ++ value
        _, acc -> acc
      end)

    if {:done, ref} in responses do
      {conn, status, headers}
    else
      receive_upgrade(conn, ref, deadline, status, headers)
    end
  end

  defp send_frame(conn, websocket, ref, frame) do
    assert {:ok, websocket, bytes} = Mint.WebSocket.encode(websocket, frame)
    assert {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, bytes)
    {conn, websocket}
  end

  defp receive_frame(conn, websocket, ref, deadline) do
    assert {:ok, conn, responses} = Mint.WebSocket.recv(conn, 0, remaining(deadline))

    {websocket, frames} =
      Enum.reduce(responses, {websocket, []}, fn
        {:data, ^ref, bytes}, {websocket, frames} ->
          assert {:ok, websocket, decoded} = Mint.WebSocket.decode(websocket, bytes)
          {websocket, frames ++ decoded}

        _, acc ->
          acc
      end)

    case frames do
      [] -> receive_frame(conn, websocket, ref, deadline)
      [frame] -> {conn, websocket, frame}
    end
  end

  defp frame_summary({:close, code, _reason}), do: "close code #{code}"
  defp frame_summary(frame), do: inspect(elem(frame, 0))
  defp deadline, do: System.monotonic_time(:millisecond) + @timeout

  defp remaining(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    assert remaining > 0, "timed out waiting for WebSocket traffic"
    remaining
  end
end
