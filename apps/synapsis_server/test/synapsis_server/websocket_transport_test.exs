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

    socket =
      HTTP.WebSocket.new("ws://127.0.0.1:#{port}/", [],
        mode: :proxy,
        http_version: :http1,
        opening_timeout: @timeout,
        connect_timeout: @timeout,
        write_timeout: @timeout,
        close_timeout: @timeout
      )

    assert %HTTP.WebSocket{} = socket

    on_exit(fn ->
      HTTP.WebSocket.close(socket)
      HTTP.ClientCompletion.await(HTTP.WebSocket.completion(socket), @timeout)
    end)

    assert_receive {HTTP.WebSocket, ^socket,
                    %HTTP.WebSocket.Event.Open{handshake: %{status: 101}}},
                   @timeout

    assert :ok = HTTP.WebSocket.send_frame(socket, {:text, "large"})
    frame = receive_frame(socket)

    assert elem(frame, 0) == :text,
           "expected a large text reply, received #{frame_summary(frame)}"

    payload = elem(frame, 1)
    assert byte_size(payload) == @payload_bytes

    assert :crypto.hash(:sha256, payload) ==
             :crypto.hash(:sha256, String.duplicate("x", @payload_bytes))

    assert :ok = HTTP.WebSocket.send_frame(socket, {:ping, "heartbeat"})
    assert receive_frame(socket) == {:pong, "heartbeat"}

    assert :ok = HTTP.WebSocket.send_frame(socket, {:text, "still-connected"})
    assert receive_frame(socket) == {:text, "still-connected"}
  end

  defp receive_frame(socket) do
    receive do
      {HTTP.WebSocket, ^socket, %HTTP.WebSocket.Event.Frame{opcode: opcode, data: data}} ->
        {opcode, data}

      {HTTP.WebSocket, ^socket, event} ->
        flunk("unexpected WebSocket event: #{inspect(event)}")
    after
      @timeout -> flunk("timed out waiting for WebSocket traffic")
    end
  end

  defp frame_summary({:close, code, _reason}), do: "close code #{code}"
  defp frame_summary(frame), do: inspect(elem(frame, 0))
end
