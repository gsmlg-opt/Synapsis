defmodule SynapsisWeb.AgentLive.ToolResultChatFunctionalTest do
  use SynapsisWeb.ConnCase, async: false

  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Agent.Tools.ResultProjection
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}
  alias Synapsis.Session.Worker.Persistence

  @moduletag :tmp_dir
  @moduletag timeout: 60_000
  @call_id "chat-native-image"
  @arguments %{"path" => "tiny.png", "detail" => "original"}
  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="

  test "native image result reaches live chat, Concord history and a new Worker replay", %{
    conn: conn,
    tmp_dir: root
  } do
    File.write!(Path.join(root, "tiny.png"), Base.decode64!(@png))

    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(harness) end)
    assert {:ok, _} = Synapsis.AgentConfigs.update(harness.agent_config, %{tools: ["view_image"]})

    assert :ok =
             Synapsis.Provider.Registry.register(harness.provider.name, %{
               type: "anthropic",
               base_url: harness.provider.base_url,
               api_key: "test-key"
             })

    owner = self()

    Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/messages", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      index =
        Agent.get_and_update(harness.counter, fn state ->
          {length(state.provider_requests),
           %{state | provider_requests: state.provider_requests ++ [request]}}
        end)

      send(owner, {:image_chat_request, index, request, self()})

      if index == 0 do
        image_call(conn)
      else
        receive do
          :complete -> text_response(conn)
        after
          10_000 -> raise "fixture completion was not released"
        end
      end
    end)

    SessionHarness.subscribe!(harness.session.id)
    route = ~p"/agent/agents/#{harness.agent_name}/sessions/#{harness.session.id}"
    {:ok, view, _html} = live(conn, route)
    assert :ok = Worker.send_message(harness.session.id, "Inspect the local PNG")
    assert_receive {:image_chat_request, 0, _first, _}, 5_000
    assert_receive {:image_chat_request, 1, following, provider}, 10_000

    live_chat = chat(view)
    tool = live_chat.messages |> Enum.flat_map(& &1.tools) |> Enum.find(&(&1.id == @call_id))
    assert tool.status == "complete"
    assert %{blocks: [text, image], isError: false} = tool.display
    assert text.type == "text"
    assert text.text =~ "Image: tiny.png"
    assert image.type == "image"
    assert image.src == "data:image/png;base64," <> @png
    assert image.mediaType == "image/png"
    assert_wire_image(following, text.text)

    send(provider, :complete)
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    assert {:ok, turns} = Store.list_turns(harness.session.id)

    assert [%{projection: projection}] =
             for(turn <- turns, part <- turn.parts, part[:type] == "tool_result", do: part)

    assert Enum.at(projection["result"]["content"], 1) == %{
             "type" => "image",
             "data" => %{"source" => "base64", "media_type" => "image/png", "data" => @png}
           }

    [{old_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    monitor = Process.monitor(old_worker)
    assert :ok = DynamicSupervisor.stop_session(harness.session.id)
    assert_receive {:DOWN, ^monitor, :process, ^old_worker, _}, 5_000

    {:ok, history_view, _} = live(conn, route)
    historical_chat = chat(history_view)
    historical = result_part(historical_chat)
    assert historical.display == tool.display
    refute Map.has_key?(historical, :projection)

    SessionHarness.ensure_running!(harness.session.id)
    [{new_worker, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    refute new_worker == old_worker
    assert :ok = Worker.send_message(harness.session.id, "Recall the already inspected image")
    assert_receive {:image_chat_request, 2, replay, replay_provider}, 10_000
    assert_wire_image(replay, text.text)
    send(replay_provider, :complete)
    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    replay_chat = chat(history_view)
    assert result_part(replay_chat).display == historical.display
    assert length(Agent.get(harness.counter, & &1.provider_requests)) == 3
    assert File.read!(Path.join(root, "tiny.png")) == Base.decode64!(@png)

    export("native-chat.json", %{
      live: live_chat,
      history: historical_chat,
      replay: replay_chat,
      png: @png
    })
  end

  test "code-agent results retain ordered public blocks and correlate interleaved calls by ID", %{
    conn: conn
  } do
    assert {:ok, session} =
             Synapsis.Sessions.create("__global__", %{
               agent: "main",
               provider: "anthropic",
               model: "fixture",
               config: %{"subagents" => false}
             })

    on_exit(fn ->
      DynamicSupervisor.stop_session(session.id)
      Synapsis.Sessions.delete(session.id)
    end)

    {:ok, view, _} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")
    sub_id = Ecto.UUID.generate()

    Persistence.broadcast(session.id, "code_agent_spawned", %{
      sub_session_id: sub_id,
      prompt: "Read fixture"
    })

    for {id, path} <- [{"first", "one.txt"}, {"second", "two.txt"}] do
      code_event(session.id, sub_id, "tool_use", %{
        tool: "fixture::read",
        tool_use_id: id,
        input: %{"path" => path}
      })
    end

    assert {:ok, first} =
             ResultProjection.to_part("first", %{
               content: [
                 %{"type" => "text", "text" => "Before image"},
                 %{"type" => "image", "mimeType" => "image/png", "data" => @png},
                 %{"type" => "text", "text" => "After image"}
               ],
               structured: %{"count" => 2},
               artifacts: [%{"path" => "tiny.png", "mime_type" => "image/png"}],
               progress: %{"completed" => 2, "total" => 2},
               pagination: %{"has_more" => false},
               status: "completed"
             })

    assert {:ok, second} = ResultProjection.to_part("second", %{content: "Second finished first"})

    for part <- [second, first] do
      code_event(session.id, sub_id, "tool_result", Map.from_struct(part))
    end

    snapshot = chat(view)
    message = Enum.find(snapshot.messages, &(&1.id == "code-agent-#{sub_id}"))
    assert [a, b] = message.metadata.codeAgent.tool_calls
    assert a.id == "first"
    assert b.id == "second"
    assert a.input == %{"path" => "one.txt"}
    assert b.input == %{"path" => "two.txt"}
    assert a.status == "complete"
    assert b.status == "complete"
    assert [%{type: "text", text: "Second finished first"}] = b.display.blocks
    assert Enum.map(a.display.blocks, & &1.type) == ["text", "image", "text"]
    assert Enum.at(a.display.blocks, 1).src == "data:image/png;base64," <> @png
    assert Enum.find(a.display.sidecars, &(&1.key == "structured")).value == %{"count" => 2}

    assert Enum.find(a.display.sidecars, &(&1.key == "pagination")).value == %{
             "has_more" => false
           }

    assert Enum.find(a.display.sidecars, &(&1.key == "metadata")).value["status"] == "completed"
    export("code-agent-chat.json", %{snapshot: snapshot, png: @png})
  end

  defp code_event(session_id, sub_id, event, payload),
    do:
      Persistence.broadcast(session_id, "code_agent_event", %{
        sub_session_id: sub_id,
        event: event,
        payload: payload
      })

  defp chat(view) do
    render(view)
    :sys.get_state(view.pid).socket.assigns.react_chat
  end

  defp result_part(snapshot),
    do:
      snapshot.messages
      |> Enum.flat_map(&(&1.metadata[:parts] || []))
      |> Enum.find(&(&1.type == "tool_result"))

  defp assert_wire_image(request, text) do
    blocks = Enum.flat_map(request["messages"], &List.wrap(&1["content"]))
    result = Enum.find(blocks, &(&1["type"] == "tool_result"))
    assert result["tool_use_id"] == @call_id
    assert result["is_error"] == false

    assert result["content"] == [
             %{"type" => "text", "text" => text},
             %{
               "type" => "image",
               "source" => %{"type" => "base64", "media_type" => "image/png", "data" => @png}
             }
           ]
  end

  defp image_call(conn) do
    sse_response(conn, [
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{
          "type" => "tool_use",
          "id" => @call_id,
          "name" => "view_image",
          "input" => %{}
        }
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "input_json_delta", "partial_json" => Jason.encode!(@arguments)}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{"type" => "message_delta", "delta" => %{"stop_reason" => "tool_use"}},
      %{"type" => "message_stop"}
    ])
  end

  defp text_response(conn) do
    sse_response(conn, [
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => "Image inspected"}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}},
      %{"type" => "message_stop"}
    ])
  end

  defp sse_response(conn, events),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(
        200,
        Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n"))
      )

  defp export(name, data) do
    if destination = System.get_env("SYNAPSIS_TOOL_RESULT_UI_EVIDENCE"),
      do: File.write!(Path.join(destination, name), Jason.encode!(data))
  end
end
