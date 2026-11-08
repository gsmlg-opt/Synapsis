defmodule SynapsisServer.SSETransportTest do
  use ExUnit.Case, async: false

  alias Synapsis.Session
  alias Synapsis.Session.Store

  @request_timeout 2_000

  setup do
    :ok = Store.ensure_started()
    session = %Session{id: Ecto.UUID.generate(), provider: "transport-test", model: "test"}
    :ok = Store.put_meta(session.id, Session.to_meta(session))
    on_exit(fn -> Store.delete_session(session.id) end)

    listener =
      start_supervised!(
        {Gaoxy.HTTP,
         id: __MODULE__,
         plug: {SynapsisServer.Endpoint, []},
         ip: {127, 0, 0, 1},
         port: 0,
         http_limits: %{request_timeout: @request_timeout}}
      )

    %{local: {:ok, {address, port}}} = Gaoxy.info(listener, __MODULE__)
    {:ok, address: address, port: port, session_id: session.id}
  end

  test "session SSE sends rich tool-result projections unchanged", %{
    address: address,
    port: port,
    session_id: session_id
  } do
    assert {:ok, socket} = :gen_tcp.connect(address, port, [:binary, active: false], 5_000)
    on_exit(fn -> :gen_tcp.close(socket) end)

    assert :ok =
             :gen_tcp.send(
               socket,
               "GET /api/sessions/#{session_id}/events HTTP/1.1\r\nHost: localhost:#{port}\r\nAccept: text/event-stream\r\n\r\n"
             )

    assert receive_until(socket, "event: session_state") =~ "HTTP/1.1 200"

    payload = %{
      "tool" => "display_fixture",
      "tool_use_id" => "rich-call",
      "content" => "before\nafter",
      "is_error" => false,
      "projection" => rich_projection()
    }

    assert :ok =
             Phoenix.PubSub.broadcast(
               Synapsis.PubSub,
               "session:#{session_id}",
               {"tool_result", payload}
             )

    wire_event = "event: tool_result\ndata: #{Jason.encode!(payload)}\n\n"
    assert receive_until(socket, wire_event) =~ wire_event
  end

  test "both SSE routes outlive request deadlines and detect disconnects despite ignored traffic",
       %{
         address: address,
         port: port,
         session_id: session_id
       } do
    routes = [
      {"/api/agent/events", "agent:daemon", "daemon_status", "backplane_sync_failed"},
      {"/api/sessions/#{session_id}/events", "session:#{session_id}", "session_state",
       "transport_probe"}
    ]

    streams =
      for {path, topic, initial_event, next_event} <- routes do
        before = subscribers(topic)
        assert {:ok, socket} = :gen_tcp.connect(address, port, [:binary, active: false], 5_000)
        on_exit(fn -> :gen_tcp.close(socket) end)

        assert :ok =
                 :gen_tcp.send(
                   socket,
                   "GET #{path} HTTP/1.1\r\nHost: localhost:#{port}\r\nAccept: text/event-stream\r\n\r\n"
                 )

        response = receive_until(socket, "event: #{initial_event}")
        assert response =~ "HTTP/1.1 200"
        assert String.downcase(response) =~ "content-type: text/event-stream"
        [owner] = subscribers(topic) |> MapSet.difference(before) |> MapSet.to_list()
        {socket, owner, Process.monitor(owner), topic, next_event}
      end

    Process.sleep(@request_timeout + 500)
    token = Ecto.UUID.generate()

    for {socket, owner, _monitor, topic, next_event} <- streams do
      assert Process.alive?(owner)

      message =
        if topic == "agent:daemon" do
          {:agent_daemon_event, %{event: "backplane.sync.failed", transport_probe: token}}
        else
          {next_event, %{transport_probe: token}}
        end

      assert :ok = Phoenix.PubSub.broadcast(Synapsis.PubSub, topic, message)
      assert receive_until(socket, token) =~ "event: #{next_event}"
    end

    topics = Enum.map(streams, &elem(&1, 3))
    test_pid = self()

    noise =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             broadcast_noise(topics)
             send(test_pid, {:noise_started, self()})
             broadcast_noise_until(topics, System.monotonic_time(:millisecond) + 5_000)
           end},
          id: :sse_disconnect_noise
        )
      )

    assert_receive {:noise_started, ^noise}, 1_000

    try do
      for {socket, owner, monitor, topic, _next_event} <- streams do
        assert :ok = :gen_tcp.close(socket)
        assert_receive {:DOWN, ^monitor, :process, ^owner, _reason}, 3_000
        assert_unsubscribed(topic, owner, 100)
      end
    after
      assert :ok = stop_supervised(:sse_disconnect_noise)
    end
  end

  defp broadcast_noise_until(topics, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      broadcast_noise(topics)
      Process.sleep(50)
      broadcast_noise_until(topics, deadline)
    end
  end

  defp broadcast_noise(topics) do
    for topic <- topics do
      Phoenix.PubSub.broadcast(Synapsis.PubSub, topic, :ignored_transport_probe)
    end
  end

  defp subscribers(topic) do
    Synapsis.PubSub
    |> Registry.lookup(topic)
    |> Enum.map(&elem(&1, 0))
    |> MapSet.new()
  end

  defp receive_until(socket, marker) do
    receive_until(socket, marker, "", System.monotonic_time(:millisecond) + 5_000)
  end

  defp receive_until(socket, marker, bytes, deadline) do
    if String.contains?(bytes, marker) do
      bytes
    else
      remaining = deadline - System.monotonic_time(:millisecond)
      assert remaining > 0
      assert byte_size(bytes) < 65_536
      assert {:ok, chunk} = :gen_tcp.recv(socket, 0, remaining)
      receive_until(socket, marker, bytes <> chunk, deadline)
    end
  end

  defp assert_unsubscribed(topic, owner, attempts) do
    if MapSet.member?(subscribers(topic), owner) and attempts > 0 do
      Process.sleep(10)
      assert_unsubscribed(topic, owner, attempts - 1)
    else
      refute MapSet.member?(subscribers(topic), owner)
    end
  end

  defp rich_projection do
    %{
      "version" => 1,
      "result" => %{
        "content" => [
          %{"type" => "text", "text" => "before"},
          %{
            "type" => "image",
            "data" => %{
              "source" => "base64",
              "media_type" => "image/png",
              "data" => "aW1hZ2U="
            }
          },
          %{"type" => "text", "text" => "after"}
        ],
        "is_error" => false,
        "structured" => %{"rows" => [%{"value" => 3}]},
        "artifacts" => [%{"uri" => "workspace://report", "name" => "report"}],
        "details" => %{"count" => 1},
        "progress" => %{"status" => "completed", "completed" => 1},
        "pagination" => %{"cursor" => "page-2", "truncated" => true},
        "metadata" => %{"opaque" => [nil, false, 4]}
      }
    }
  end
end
