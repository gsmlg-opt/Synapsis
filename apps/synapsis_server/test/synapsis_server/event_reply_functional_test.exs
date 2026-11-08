defmodule SynapsisServer.EventReplyFunctionalTest do
  use ExUnit.Case, async: false

  import Phoenix.ChannelTest
  import Synapsis.Agent.DaemonCase, only: [wait_for: 1]

  alias Synapsis.Agent.TestSupport.DeterministicProvider
  alias Synapsis.Session.{Store, Worker}
  alias Synapsis.{Message, Part, Sessions}

  @endpoint SynapsisServer.Endpoint
  @moduletag :tmp_dir
  @timeout 5_000

  setup ctx do
    listener =
      start_supervised!(
        {Gaoxy.HTTP, id: __MODULE__, plug: {@endpoint, []}, ip: {127, 0, 0, 1}, port: 0}
      )

    %{local: {:ok, {_address, port}}} = Gaoxy.info(listener, __MODULE__)
    fixture = fixture(ctx.tmp_dir)
    {:ok, Map.merge(fixture, %{port: port, host: "http://127.0.0.1:#{port}"})}
  end

  test "REST and channel history preserve raw authored parts and add the same event display projection",
       ctx do
    occurrence = Ecto.UUID.generate()
    stamp = %{"version" => 1, "policy" => "manual_event_message", "occurrence_id" => occurrence}
    raw = "HEARTBEAT_OK Ready🙂"
    image = %Part.Image{media_type: "image/png", data: "aW1hZ2U="}
    event = message(ctx.id, raw) |> Map.put(:reply_presentation, stamp)
    event = %{event | parts: event.parts ++ [image]}
    quiet = message(ctx.id, "HEARTBEAT_OK") |> Map.put(:reply_presentation, stamp)
    ordinary = message(ctx.id, "HEARTBEAT_OK ordinary")
    assert {:ok, meta} = Store.get_meta(ctx.id)

    assert :ok =
             Store.commit_turns(
               ctx.id,
               0,
               Enum.map([event, quiet, ordinary], &Message.encode/1),
               meta
             )

    assert {:ok,
            %{
              status: 200,
              body: %{"data" => %{"messages" => [rest_event, rest_quiet, rest_ordinary]}}
            }} =
             Req.get(ctx.host <> "/api/sessions/#{ctx.id}", retry: false)

    assert rest_event["id"] == event.id

    assert rest_event["parts"] == [
             %{"type" => "text", "content" => raw},
             %{"type" => "image", "media_type" => "image/png", "data" => "aW1hZ2U="}
           ]

    projection = %{
      "version" => 1,
      "policy" => "manual_event_message",
      "occurrence_id" => occurrence,
      "hidden" => false,
      "text" => "Ready🙂",
      "text_parts" => [%{"index" => 0, "text" => "Ready🙂"}]
    }

    assert rest_event["reply_presentation"] == projection
    assert rest_quiet["parts"] == [%{"type" => "text", "content" => "HEARTBEAT_OK"}]
    assert rest_quiet["reply_presentation"]["hidden"] == true

    assert rest_ordinary == %{
             "id" => ordinary.id,
             "role" => "assistant",
             "token_count" => 0,
             "inserted_at" => DateTime.to_iso8601(ordinary.inserted_at),
             "parts" => [%{"type" => "text", "content" => "HEARTBEAT_OK ordinary"}]
           }

    assert {:ok, socket} = connect(SynapsisServer.UserSocket, %{})

    assert {:ok, %{messages: [channel_event, channel_quiet, channel_ordinary]}, _socket} =
             join(socket, "session:#{ctx.id}", %{})

    assert channel_event.id == event.id
    assert Jason.decode!(Jason.encode!(channel_event.parts)) == rest_event["parts"]
    assert Jason.decode!(Jason.encode!(channel_event.reply_presentation)) == projection
    assert channel_quiet.reply_presentation.hidden == true

    assert channel_ordinary == %{
             id: ordinary.id,
             role: "assistant",
             inserted_at: ordinary.inserted_at,
             parts: [%{type: "text", content: "HEARTBEAT_OK ordinary"}]
           }

    assert [^event, ^quiet, ^ordinary] = Message.list_by_session(ctx.id)
  end

  test "actual event stream state joins from the live Worker view and forwards acknowledged projections",
       ctx do
    owner = self()
    raw = "HEARTBEAT_OK Ready🙂"

    Gaoxy.Test.expect_once(ctx.provider, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      assert %{
               "role" => "user",
               "content" => [%{"type" => "text", "text" => "manual event notice"}]
             } =
               List.last(request["messages"])

      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      assert {:ok, conn} =
               Plug.Conn.chunk(
                 conn,
                 "data: #{Jason.encode!(DeterministicProvider.text_chunk(raw))}\n\n"
               )

      send(owner, {:event_provider_held, self()})

      receive do
        :finish_event_reply ->
          DeterministicProvider.send_sse(conn, [DeterministicProvider.finish_chunk("stop")])
      after
        15_000 -> flunk("event provider gate was not released")
      end
    end)

    assert :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "session:#{ctx.id}")

    assert {:ok, %{event_id: occurrence, accepted: true}} =
             Sessions.wake(ctx.id, "manual event notice",
               target_agent_id: ctx.agent.id,
               source_agent_id: ctx.agent.id,
               source_session_id: ctx.id
             )

    assert_receive {:event_provider_held, handler}, @timeout
    on_exit(fn -> send(handler, :finish_event_reply) end)
    assert_receive {"text_delta", %{text: ^raw, reply_presentation: view}}, @timeout
    assert view.occurrence_id == occurrence
    assert view.text == "Ready🙂"
    assert Worker.snapshot(ctx.id).in_flight_text == raw
    live_view = Worker.snapshot(ctx.id).reply_presentation
    assert Map.take(live_view, Map.keys(view)) == view
    assert live_view.committed_messages == []

    assert {:ok, %{status: 200, body: %{"data" => rest}}} =
             Req.get(ctx.host <> "/api/sessions/#{ctx.id}", retry: false)

    assert rest["in_flight"] == raw
    assert rest["reply_presentation"] == Jason.decode!(Jason.encode!(live_view))
    assert {:ok, socket} = connect(SynapsisServer.UserSocket, %{})
    assert {:ok, joined, _socket} = join(socket, "session:#{ctx.id}", %{})
    assert joined.reply_presentation == live_view

    assert {:ok, conn} =
             Mint.HTTP.connect(:http, "127.0.0.1", ctx.port,
               mode: :passive,
               protocols: [:http1],
               transport_opts: [timeout: @timeout]
             )

    on_exit(fn -> :gen_tcp.close(Mint.HTTP.get_socket(conn)) end)

    assert {:ok, conn, ref} =
             Mint.HTTP.request(conn, "GET", "/api/sessions/#{ctx.id}/events", [], nil)

    {conn, initial, _wire} = receive_frame(conn, ref, "session_state")
    assert initial["in_flight"] == raw
    assert initial["reply_presentation"] == Jason.decode!(Jason.encode!(live_view))

    send(handler, :finish_event_reply)

    assert_receive {"reply_presentation",
                    %{phase: "committed", message_id: message_id} = committed},
                   @timeout

    assert committed.text == "Ready🙂"

    assert_push "reply_presentation",
                %{phase: "committed", message_id: ^message_id, text: "Ready🙂"},
                @timeout

    {_conn, delivered, _wire} =
      receive_frame(conn, ref, "reply_presentation", "\"phase\":\"committed\"")

    assert delivered == Jason.decode!(Jason.encode!(committed))
    assert_receive {"done", _payload}, @timeout
    assert [_, saved] = Message.list_by_session(ctx.id)
    assert saved.id == message_id
    assert saved.parts == [%Part.Text{content: raw}]

    assert Map.get(saved, :reply_presentation) == %{
             "version" => 1,
             "policy" => "manual_event_message",
             "occurrence_id" => occurrence
           }
  end

  test "ordinary initial live serializers retain their existing shape without a presentation object",
       ctx do
    assert :ok = Sessions.ensure_running(ctx.id)

    assert {:ok, :idle} =
             wait_for(fn ->
               case Worker.public_status(ctx.id) do
                 {:ok, %{runtime: %{phase: "idle", active: false}}} -> {:ok, :idle}
                 _ -> :retry
               end
             end)

    assert {:ok, %{status: 200, body: %{"data" => rest}}} =
             Req.get(ctx.host <> "/api/sessions/#{ctx.id}", retry: false)

    assert rest["in_flight"] == ""
    refute Map.has_key?(rest, "reply_presentation")
    assert {:ok, socket} = connect(SynapsisServer.UserSocket, %{})
    assert {:ok, joined, _socket} = join(socket, "session:#{ctx.id}", %{})
    assert Map.keys(joined) |> Enum.sort() == [:debug, :debug_entries, :messages]

    assert {:ok, conn} =
             Mint.HTTP.connect(:http, "127.0.0.1", ctx.port,
               mode: :passive,
               protocols: [:http1],
               transport_opts: [timeout: @timeout]
             )

    on_exit(fn -> :gen_tcp.close(Mint.HTTP.get_socket(conn)) end)

    assert {:ok, conn, ref} =
             Mint.HTTP.request(conn, "GET", "/api/sessions/#{ctx.id}/events", [], nil)

    {_conn, initial, _wire} = receive_frame(conn, ref, "session_state")

    assert initial == %{
             "live" => true,
             "status" => to_string(Worker.snapshot(ctx.id).status),
             "in_flight" => ""
           }
  end

  defp fixture(root) do
    provider = Gaoxy.Test.open()
    name = "event-reply-server-#{Ecto.UUID.generate()}"

    assert :ok =
             Synapsis.Provider.Registry.register(name, %{
               type: "openai",
               api_key: "test-key",
               base_url: String.trim_trailing(Gaoxy.Test.url(provider), "/")
             })

    assert {:ok, agent} =
             Synapsis.AgentConfigs.create(%{
               name: name,
               provider: name,
               model: "event-reply-model",
               tools: [],
               tool_contract_version: 1,
               config: %{"workspace_path" => root}
             })

    assert {:ok, session} =
             Sessions.create(name, %{
               agent: name,
               config: %{
                 "workspace_path" => root,
                 "subagents" => false,
                 "memory_context" => false
               }
             })

    on_exit(fn ->
      Sessions.delete(session.id)
      Synapsis.AgentConfigs.delete(agent)
      Synapsis.Provider.Registry.unregister(name)
    end)

    %{id: session.id, agent: agent, provider: provider}
  end

  defp message(id, raw),
    do: %Message{
      id: Ecto.UUID.generate(),
      session_id: id,
      role: "assistant",
      inserted_at: ~U[2026-10-28 03:00:00.000000Z],
      parts: [%Part.Text{content: raw}]
    }

  defp receive_frame(conn, ref, event, marker \\ "", bytes \\ "", deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @timeout
    pattern = ~r/event: #{event}\ndata: ([^\n]*)\n\n/
    matches = Regex.scan(pattern, bytes)

    case Enum.find(matches, fn [_, data] -> String.contains?(data, marker) end) do
      [_, data] ->
        {conn, Jason.decode!(data), bytes}

      nil ->
        remaining = deadline - System.monotonic_time(:millisecond)
        assert remaining > 0, "SSE did not deliver #{event} #{marker}"
        assert {:ok, conn, responses} = Mint.HTTP.recv(conn, 0, remaining)

        body =
          Enum.flat_map(responses, fn
            {:data, ^ref, data} -> [data]
            _ -> []
          end)

        receive_frame(conn, ref, event, marker, bytes <> IO.iodata_to_binary(body), deadline)
    end
  end
end
