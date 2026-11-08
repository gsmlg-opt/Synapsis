defmodule SynapsisWeb.AgentLive.EventReplyFunctionalTest do
  use SynapsisWeb.ConnCase, async: false

  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}
  alias Synapsis.{Message, Part, Sessions}

  @moduletag :tmp_dir
  @raw "HEARTBEAT_OK all good🙂"

  test "event replacements, reconnect and durable reload agree while authored text stays raw",
       ctx do
    h = fixture(ctx.tmp_dir)
    id = h.session.id
    route = ~p"/agent/agents/#{h.agent_name}/sessions/#{id}"
    {:ok, view, _} = live(ctx.conn, route)

    assert {:ok, %{event_id: occurrence}} =
             Sessions.wake(id, "Present this manual event",
               target_agent_id: h.agent_config.id,
               source_agent_id: h.agent_config.id,
               source_session_id: id
             )

    assert_receive {:display_provider, provider}, 10_000
    send(provider, {:text, "HEARTBEAT_"})
    assert_receive {"text_delta", %{text: "HEARTBEAT_", reply_presentation: prefix}}, 10_000
    assert prefix.occurrence_id == occurrence
    assert live_text(view) == "HEARTBEAT_"
    send(provider, {:text, "OK"})
    assert_receive {"text_delta", %{text: "OK", reply_presentation: marker}}, 10_000
    assert marker.revision > prefix.revision
    assert live_text(view) == ""
    assert_push_event(view, "chat:event", %{type: "chat.message", message: %{content: ""}})

    send(provider, {:text, " all good🙂"})
    assert_receive {"text_delta", %{text: " all good🙂", reply_presentation: visible}}, 10_000
    assert visible.revision > marker.revision
    assert live_text(view) == "all good🙂"
    assert Worker.snapshot(id).in_flight_text == @raw
    {:ok, connected, _} = live(ctx.conn, route)
    assert live_text(connected) == "all good🙂"

    send(provider, :complete)
    assert_receive {"done", _}, 10_000
    assert_completed(view)
    assert_completed(connected)
    assert {:ok, turns} = Store.list_turns(id)
    authored = Enum.find(turns, &(&1.role == "assistant"))
    assert authored.parts == [%{type: "text", text: @raw}]
    assert authored.reply_presentation["occurrence_id"] == occurrence
    [_, raw] = Sessions.get_messages(id)
    assert [%Part.Text{content: @raw}] = raw.parts
    assert raw.reply_presentation == authored.reply_presentation

    [{old, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    monitor = Process.monitor(old)
    assert :ok = DynamicSupervisor.stop_session(id)
    assert_receive {:DOWN, ^monitor, :process, ^old, _}, 5_000
    {:ok, reloaded, _} = live(ctx.conn, route)
    assert_completed(reloaded)
    assert [%Part.Text{content: @raw}] = List.last(Sessions.get_messages(id)).parts
  end

  test "ordinary literal marker text keeps immediate raw streaming and history", ctx do
    h = fixture(ctx.tmp_dir)
    id = h.session.id
    {:ok, view, _} = live(ctx.conn, ~p"/agent/agents/#{h.agent_name}/sessions/#{id}")
    assert :ok = Worker.send_message(id, "Ordinary prompt")
    assert_receive {:display_provider, provider}, 10_000
    send(provider, {:text, @raw})
    assert_receive {"text_delta", delta}, 10_000
    assert delta == %{text: @raw}
    assert live_text(view) == @raw
    assert_push_event(view, "chat:event", %{type: "chat.delta", text: @raw})
    send(provider, :complete)
    assert_receive {"done", _}, 10_000
    [_, raw] = Sessions.get_messages(id)
    assert Map.get(raw, :reply_presentation) == nil
    assert List.last(chat(view).messages).content == @raw
  end

  test "ordinary reasoning remains visible after a completed manual event", ctx do
    h = fixture(ctx.tmp_dir)
    id = h.session.id
    {:ok, view, _} = live(ctx.conn, ~p"/agent/agents/#{h.agent_name}/sessions/#{id}")

    assert {:ok, _} =
             Sessions.wake(id, "First manual event",
               target_agent_id: h.agent_config.id,
               source_agent_id: h.agent_config.id,
               source_session_id: id
             )

    assert_receive {:display_provider, event_provider}, 10_000
    send(event_provider, {:text, @raw})
    assert_receive {"text_delta", _}, 10_000
    send(event_provider, :complete)
    assert_receive {"done", _}, 10_000
    assert_completed(view)

    assert :ok = Worker.send_message(id, "Next ordinary prompt")
    assert_receive {:display_provider, ordinary_provider}, 10_000
    send(ordinary_provider, {:reasoning, "Considering the next step"})
    assert_receive {"reasoning", %{text: "Considering the next step"}}, 10_000
    assert [live] = Enum.filter(chat(view).messages, &String.starts_with?(&1.id, "agent-live-"))
    assert live.metadata.reasoning == "Considering the next step"
    assert live.content == ""
    assert :sys.get_state(view.pid).socket.assigns.reply_presentation == nil
    send(ordinary_provider, :complete)
    assert_receive {"done", _}, 10_000
  end

  test "a following manual event exposes reasoning before its first text", ctx do
    h = fixture(ctx.tmp_dir)
    id = h.session.id
    {:ok, view, _} = live(ctx.conn, ~p"/agent/agents/#{h.agent_name}/sessions/#{id}")

    options = [
      target_agent_id: h.agent_config.id,
      source_agent_id: h.agent_config.id,
      source_session_id: id
    ]

    assert {:ok, _} = Sessions.wake(id, "First event", options)
    assert_receive {:display_provider, first}, 10_000
    send(first, {:text, @raw})
    assert_receive {"text_delta", _}, 10_000
    send(first, :complete)
    assert_receive {"done", _}, 10_000
    assert_completed(view)

    assert {:ok, %{event_id: next_occurrence}} = Sessions.wake(id, "Following event", options)
    assert_receive {:display_provider, second}, 10_000
    send(second, {:reasoning, "Considering the following event"})
    assert_receive {"reasoning", %{text: "Considering the following event"}}, 10_000
    assert [live] = Enum.filter(chat(view).messages, &String.starts_with?(&1.id, "agent-live-"))
    assert live.metadata.reasoning == "Considering the following event"
    assert live.content == ""

    assert :sys.get_state(view.pid).socket.assigns.reply_presentation.occurrence_id ==
             next_occurrence

    send(second, {:text, "HEARTBEAT_OK Next event"})
    assert_receive {"text_delta", _}, 10_000
    assert live_text(view) == "Next event"
    send(second, :complete)
    assert_receive {"done", _}, 10_000

    assert Enum.map(Enum.filter(chat(view).messages, &(&1.role == "assistant")), & &1.content) ==
             ["all good🙂", "Next event"]
  end

  test "tagged captions retain media and nested tool text and hide only textless rows", ctx do
    h = fixture(ctx.tmp_dir)
    id = h.session.id
    assert :ok = DynamicSupervisor.stop_session(id)

    stamp = %{
      "version" => 1,
      "policy" => "manual_event_message",
      "occurrence_id" => Ecto.UUID.generate()
    }

    media = %Part.Image{media_type: "image/png", data: "fixture-image"}
    nested = %Part.ToolResult{tool_use_id: "kept", content: "HEARTBEAT_OK inside a tool"}

    messages = [
      struct(Message,
        id: Ecto.UUID.generate(),
        session_id: id,
        role: "assistant",
        parts: [%Part.Text{content: "HEARTBEAT_OK"}],
        reply_presentation: stamp
      ),
      struct(Message,
        id: Ecto.UUID.generate(),
        session_id: id,
        role: "assistant",
        parts: [%Part.Text{content: "HEARTBEAT_OK"}, media, nested],
        reply_presentation: stamp
      )
    ]

    assert :ok = Message.persist_list(id, messages)
    {:ok, view, _} = live(ctx.conn, ~p"/agent/agents/#{h.agent_name}/sessions/#{id}")
    assert [visible] = chat(view).messages
    assert visible.id == List.last(messages).id
    assert visible.content == ""
    assert [%{type: "text", content: ""}, image, tool] = visible.metadata.parts
    assert image.data == media.data
    assert tool.content == nested.content

    assert [%Part.Text{content: "HEARTBEAT_OK"}, ^media, ^nested] =
             List.last(Sessions.get_messages(id)).parts
  end

  defp fixture(root) do
    h =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    owner = self()

    Gaoxy.Test.stub(h.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, _, conn} = Plug.Conn.read_body(conn)

      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      send(owner, {:display_provider, self()})
      stream(conn)
    end)

    SessionHarness.subscribe!(h.session.id)
    on_exit(fn -> SessionHarness.cleanup!(h) end)
    h
  end

  defp stream(conn) do
    receive do
      {:reasoning, text} ->
        {:ok, conn} =
          Plug.Conn.chunk(
            conn,
            frame(%{
              "choices" => [
                %{"index" => 0, "delta" => %{"reasoning_content" => text}, "finish_reason" => nil}
              ]
            })
          )

        stream(conn)

      {:text, text} ->
        {:ok, conn} =
          Plug.Conn.chunk(
            conn,
            frame(%{
              "choices" => [
                %{
                  "index" => 0,
                  "delta" => %{"role" => "assistant", "content" => text},
                  "finish_reason" => nil
                }
              ]
            })
          )

        stream(conn)

      :complete ->
        {:ok, conn} =
          Plug.Conn.chunk(
            conn,
            frame(%{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]})
          )

        {:ok, conn} = Plug.Conn.chunk(conn, "data: [DONE]\n\n")
        conn
    after
      15_000 -> raise "ordinary display fixture was not released"
    end
  end

  defp frame(data), do: "data: " <> Jason.encode!(data) <> "\n\n"

  defp chat(view) do
    render(view)
    :sys.get_state(view.pid).socket.assigns.react_chat
  end

  defp live_text(view) do
    chat(view).messages
    |> Enum.filter(&String.starts_with?(&1.id, "agent-live-"))
    |> Enum.map_join("", & &1.content)
  end

  defp assert_completed(view) do
    assert [message] = Enum.filter(chat(view).messages, &(&1.role == "assistant"))
    assert message.content == "all good🙂"
    assert message.status == "complete"
  end
end
