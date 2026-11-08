defmodule SynapsisWeb.AgentLive.MusicCompletionDeliveryFunctionalTest do
  use SynapsisWeb.ConnCase, async: false

  import Synapsis.Agent.DaemonCase, only: [wait_for: 1]

  alias Synapsis.Agent.MediaDelivery
  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Part.{Audio, Text}
  alias Synapsis.Session.{PendingInputStore, Store, Worker}
  alias Synapsis.Workspace.Media
  alias Synapsis.{Message, Sessions}
  alias SynapsisWeb.AgentLive.SessionChat
  alias SynapsisWeb.AgentLive.Sessions, as: LiveSessions

  @moduletag :tmp_dir
  @original "Original music delivery turn"
  @result "Two published tracks 雪 😀"
  @follow_up " \uFEFFInternal music completion café\n  Keep exact follow-up bytes  \n "
  @streaming "Music follow-up is streaming 雪 "

  test "shared projection keeps ordinary and cron input and assistant artifacts while hiding the exact internal music input" do
    id = Ecto.UUID.generate()
    agent_id = Ecto.UUID.generate()
    attrs = %{task_id: Ecto.UUID.generate()}
    source = provenance(id, agent_id, attrs)
    on_exit(fn -> Store.delete_session(id) end)

    ordinary = message(id, "user", "Ordinary user keeps this text")

    cron = %{
      message(id, "user", "Manual cron event remains visible")
      | internal_turn_source: "event",
        input_provenance: %{"kind" => "internal_system", "source_tool" => "cron"}
    }

    assistant = %{message(id, "assistant", @result) | input_provenance: source}

    ordinary_source = %{
      message(id, "user", "Ordinary source-tagged input")
      | input_provenance: source
    }

    internal = %{
      message(id, "user", @follow_up)
      | internal_turn_source: "event",
        input_provenance: source
    }

    raw = [ordinary, cron, assistant, ordinary_source, internal]
    assert :ok = Message.persist_list(id, raw, %{status: "idle", title: "Music projection"})
    assert Message.list_by_session(id) === raw
    snapshot = SessionChat.snapshot(snapshot_assigns(id, Message.list_by_session(id)))
    visible = [ordinary, cron, assistant, ordinary_source]
    assert Enum.map(snapshot.messages, & &1.id) === Enum.map(visible, & &1.id)
    assert Enum.map(snapshot.messages, & &1.content) === Enum.map(visible, &text/1)
    assert Enum.all?(snapshot.messages, &(&1.id != internal.id))
    assert Enum.all?(snapshot.messages, &(&1.content != @follow_up))
    assert List.last(Message.list_by_session(id)) === internal
  end

  test "committed music notification refreshes a real session socket while retaining active text reasoning and tools",
       %{conn: conn, tmp_dir: root} do
    h = fixture(root)
    id = h.session.id
    route = ~p"/agent/agents/#{h.agent_name}/sessions/#{id}"
    assert {:ok, view, _} = live(conn, route)
    original_socket = socket(view)
    attrs = %{task_id: Ecto.UUID.generate()}
    source = provenance(id, h.agent_config.id, attrs)
    artifact = %{message(id, "assistant", @result) | input_provenance: source}

    internal = %{
      message(id, "user", @follow_up)
      | input_provenance: source,
        internal_turn_source: "event"
    }

    assert {:ok, meta} = Store.get_meta(id)
    assert :ok = Message.persist_list(id, [artifact, internal], meta)

    tools = %{
      "ordinary-live-tool" => %{name: "read", status: "running", input: %{"path" => "song.txt"}}
    }

    seeded =
      Phoenix.Component.assign(original_socket,
        session_status: "tool_executing",
        streaming_text: "Existing active answer 雪",
        streaming_reasoning: "Existing reasoning café",
        tool_calls: tools
      )

    assert {:noreply, updated} =
             LiveSessions.handle_info(
               {"music_completion_applied", %{session_id: id, event_id: internal.id}},
               seeded
             )

    assert updated.assigns.messages === [artifact, internal]

    for field <- [:session_status, :streaming_text, :streaming_reasoning, :tool_calls] do
      assert Map.fetch!(updated.assigns, field) === Map.fetch!(seeded.assigns, field)
    end

    current = updated.assigns.react_chat
    assert current.runtime === %{phase: "tool_executing", active: true}
    assert Enum.map(current.messages, & &1.id) === [artifact.id, SessionChat.live_id(id)]
    active = List.last(current.messages)
    assert active.content === "Existing active answer 雪"
    assert active.metadata.reasoning === "Existing reasoning café"

    assert active.tools === [
             %{
               id: "ordinary-live-tool",
               name: "read",
               status: "running",
               input: %{"path" => "song.txt"},
               result: nil,
               display: nil
             }
           ]

    assert Message.list_by_session(id) === [artifact, internal]
  end

  test "actual completion publishes ordered audio to held live chat HTTP and reopened island while the internal turn stays raw",
       %{conn: conn, tmp_dir: root} do
    h = fixture(root)
    id = h.session.id
    media_root = Path.join(root, "published-music")
    attrs = completion(h, media_root)
    [first_audio, second_audio] = attrs.audio_parts

    urls =
      Enum.map(attrs.audio_parts, fn part ->
        assert {:ok, url} = MediaDelivery.url(part.delivery)
        url
      end)

    expected_parts = [
      %{type: "text", content: @result}
      | Enum.map(Enum.zip(attrs.audio_parts, urls), &audio_block/1)
    ]

    route = ~p"/agent/agents/#{h.agent_name}/sessions/#{id}"
    assert {:ok, view, _} = live(conn, route)
    assert :ok = Worker.send_message(id, @original)
    assert_receive {:music_ui_request, 0, original, original_handler}, 10_000
    assert List.last(user_texts(original)) === @original

    assert {:ok, %{event_id: event_id, duplicate: false}} =
             Sessions.stage_music_completion(id, attrs)

    assert event_id === attrs.id

    assert {:ok, %{event_id: ^event_id, duplicate: true}} =
             Sessions.stage_music_completion(id, attrs)

    assert request_count(h) === 1
    send(original_handler, :release_music_ui)

    assert_receive {"music_completion_applied", %{session_id: ^id, event_id: ^event_id}}, 10_000
    assert_receive {:music_ui_request, 1, following, following_handler}, 10_000
    assert List.last(user_texts(following)) === @follow_up

    assert Enum.any?(following["messages"], fn m ->
             m["role"] == "assistant" and wire_text(m["content"]) =~ @result and
               wire_text(m["content"]) =~ first_audio.descriptor["uri"] and
               wire_text(m["content"]) =~ second_audio.descriptor["uri"]
           end)

    assert {:ok, held} =
             wait_for(fn ->
               current = chat(view)
               artifact = Enum.find(current.messages, &(&1.id == attrs.artifact_message_id))
               active = Enum.find(current.messages, &(&1.id == SessionChat.live_id(id)))

               if artifact && active && active.content == @streaming,
                 do: {:ok, current},
                 else: :retry
             end)

    assert held.runtime === %{phase: "streaming", active: true}
    artifact = Enum.find(held.messages, &(&1.id == attrs.artifact_message_id))
    assert artifact.metadata.parts === expected_parts
    assert Enum.count(held.messages, &(&1.id == attrs.artifact_message_id)) === 1
    assert Enum.all?(held.messages, &(&1.id != attrs.id and &1.content != @follow_up))
    live_message = List.last(held.messages)
    assert live_message.id === SessionChat.live_id(id)
    assert live_message.status === "streaming"
    assert live_message.content === @streaming
    raw = Message.list_by_session(id)
    assert Enum.at(raw, 2).id === attrs.artifact_message_id
    assert Enum.at(raw, 2).parts === [%Text{content: @result} | attrs.audio_parts]
    assert List.last(raw).id === attrs.id
    assert List.last(raw).internal_turn_source === "event"
    assert List.last(raw).parts === [%Text{content: @follow_up}]
    assert Enum.map(socket(view).assigns.messages, & &1.id) === Enum.map(raw, & &1.id)

    files_before = audio_files(media_root)
    assert Enum.sort(Map.values(files_before)) === Enum.sort([wav(1), wav(2)])
    assert_http_audio(conn, urls, [wav(1), wav(2)])
    send(following_handler, :release_music_ui)
    completed = await_event(id, attrs.id, "completed")
    await_idle(id)

    assert {:ok, settled} =
             wait_for(fn ->
               current = chat(view)

               if current.runtime == %{phase: "idle", active: false} and
                    Enum.any?(current.messages, &(&1.content == @streaming <> "completed")),
                  do: {:ok, current},
                  else: :retry
             end)

    assert Enum.find(settled.messages, &(&1.id == attrs.artifact_message_id)).metadata.parts ===
             expected_parts

    assert Enum.all?(settled.messages, &(&1.id != attrs.id and &1.content != @follow_up))
    persisted = Message.list_by_session(id)
    assert {:ok, completed_snapshot} = Store.read_pending_inputs(id)

    assert {:ok, %{event_id: ^event_id, duplicate: true, phase: "completed"}} =
             Sessions.stage_music_completion(id, attrs)

    await_idle(id)
    assert request_count(h) === 2
    assert Message.list_by_session(id) === persisted
    assert Store.read_pending_inputs(id) === {:ok, completed_snapshot}
    assert Enum.count(chat(view).messages, &(&1.id == attrs.artifact_message_id)) === 1

    assert {:ok, reopened, html} = live(conn, route)
    history = chat(reopened)

    assert Enum.find(history.messages, &(&1.id == attrs.artifact_message_id)).metadata.parts ===
             expected_parts

    assert Enum.all?(history.messages, &(&1.id != attrs.id and &1.content != @follow_up))

    [island_json] =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-chat]")
      |> LazyHTML.attribute("data-chat")

    island = Jason.decode!(island_json)
    island_artifact = Enum.find(island["messages"], &(&1["id"] == attrs.artifact_message_id))
    assert island_artifact["metadata"]["parts"] === Jason.decode!(Jason.encode!(expected_parts))
    assert Enum.all?(island["messages"], &(&1["id"] != attrs.id and &1["content"] != @follow_up))
    assert Enum.count(island["messages"], &(&1["id"] == attrs.artifact_message_id)) === 1
    assert audio_files(media_root) === files_before
    assert_http_audio(conn, urls, [wav(1), wav(2)])
    assert Message.list_by_session(id) === persisted
    assert {:ok, [^completed]} = PendingInputStore.list_result(id)
    assert request_count(h) === 2

    if destination = System.get_env("MUSIC_COMPLETION_UI_EVIDENCE") do
      File.write!(
        destination,
        Jason.encode!(%{
          held: held,
          history: history,
          reloadedIsland: island,
          artifactMessageId: attrs.artifact_message_id,
          internalMessageId: attrs.id,
          internalFollowup: @follow_up,
          urls: urls,
          source: provenance(id, h.agent_config.id, attrs),
          audio:
            Enum.map(Enum.zip([urls, attrs.audio_parts, [wav(1), wav(2)]]), fn {url, part, bytes} ->
              %{
                url: url,
                mime: "audio/wav",
                base64: Base.encode64(bytes),
                descriptor: part.descriptor,
                delivery: part.delivery,
                name: part.name
              }
            end)
        })
      )
    end
  end

  defp fixture(root) do
    h =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        agent_name: "music-ui-#{Ecto.UUID.generate()}",
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    owner = self()
    SessionHarness.subscribe!(h.session.id)

    Gaoxy.Test.stub(h.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      handler = self()

      index =
        Agent.get_and_update(h.counter, fn state ->
          entries = state.provider_requests

          {length(entries),
           %{state | provider_requests: entries ++ [%{request: request, handler: handler}]}}
        end)

      if index == 1 do
        conn =
          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_chunked(200)

        {:ok, conn} =
          Plug.Conn.chunk(
            conn,
            "data: " <> Jason.encode!(DeterministicProvider.text_chunk(@streaming)) <> "\n\n"
          )

        send(owner, {:music_ui_request, index, request, handler})
        hold_music()

        DeterministicProvider.send_sse(conn, [
          DeterministicProvider.text_chunk("completed"),
          DeterministicProvider.finish_chunk("stop")
        ])
      else
        send(owner, {:music_ui_request, index, request, handler})
        hold_music()

        DeterministicProvider.send_sse(conn, [
          DeterministicProvider.text_chunk("Original completed"),
          DeterministicProvider.finish_chunk("stop")
        ])
      end
    end)

    on_exit(fn ->
      if Process.alive?(h.counter) do
        for entry <- Agent.get(h.counter, & &1.provider_requests),
            do: send(entry.handler, :release_music_ui)
      end

      SessionHarness.cleanup!(h)
    end)

    h
  end

  defp hold_music do
    receive do
      :release_music_ui -> :ok
    after
      20_000 -> raise "music UI successful release handshake timed out"
    end
  end

  defp completion(h, root) do
    task_id = Ecto.UUID.generate()

    audios =
      for {index, name} <- [{1, "First music 雪.wav"}, {2, "Second music 😀.wav"}] do
        assert {:ok, descriptor} = Media.put_audio(wav(index), "wav", root: root)

        invocation = %{
          run_id: Ecto.UUID.generate(),
          invocation_id: Ecto.UUID.generate(),
          tool_call_id: "music-#{task_id}-track-#{index}",
          tool_name: "music_generate"
        }

        assert {:ok, delivery} =
                 MediaDelivery.publish(descriptor, h.session.id, invocation,
                   root: root,
                   max_bytes: 4_096
                 )

        %Audio{descriptor: descriptor, delivery: delivery, name: name}
      end

    %{
      id: Ecto.UUID.generate(),
      artifact_message_id: Ecto.UUID.generate(),
      agent_id: h.agent_config.id,
      task_id: task_id,
      result: @result,
      follow_up: @follow_up,
      audio_parts: audios
    }
  end

  defp wav(multiplier) do
    pcm = for sample <- 0..127, into: <<>>, do: <<sample * multiplier * 100::signed-little-16>>

    <<"RIFF", 36 + byte_size(pcm)::little-32, "WAVEfmt ", 16::little-32, 1::little-16,
      1::little-16, 8_000::little-32, 16_000::little-32, 2::little-16, 16::little-16, "data",
      byte_size(pcm)::little-32, pcm::binary>>
  end

  defp audio_block({audio, url}),
    do: %{type: "audio", src: url, mediaType: "audio/wav", filename: audio.name}

  defp assert_http_audio(conn, urls, audios) do
    for {url, bytes} <- Enum.zip(urls, audios) do
      served = get(recycle(conn), url)
      assert response(served, 200) === bytes
      assert get_resp_header(served, "content-type") === ["audio/wav"]
      assert get_resp_header(served, "content-length") === [Integer.to_string(byte_size(bytes))]
    end
  end

  defp audio_files(root),
    do: Map.new(Path.wildcard(Path.join(root, "**/*.wav")), &{&1, File.read!(&1)})

  defp message(id, role, content),
    do: %Message{
      id: Ecto.UUID.generate(),
      session_id: id,
      role: role,
      parts: [%Text{content: content}]
    }

  defp text(message), do: Enum.map_join(message.parts, "", & &1.content)

  defp provenance(session_id, agent_id, attrs) do
    %{
      "kind" => "inter_session",
      "event_type" => "task_completion",
      "source_tool" => "music_generate",
      "source_session_key" => "music_generate:" <> attrs.task_id,
      "follow_up_id" => "music_generate:" <> attrs.task_id <> ":ok:agent-loop",
      "source_session_id" => session_id,
      "source_agent_id" => agent_id,
      "task_id" => attrs.task_id,
      "announce_id" => "music_generate:" <> attrs.task_id <> ":ok"
    }
  end

  defp snapshot_assigns(id, messages) do
    %{
      messages: messages,
      session_status: "idle",
      current_session: %{id: id, config: %{}},
      agent_config: %{label: "Music", icon: nil},
      agent_id: "music",
      streaming_text: "",
      streaming_reasoning: "",
      tool_calls: %{},
      permission_requests: [],
      queued_inputs: [],
      heartbeat_notifications: [],
      code_agent_sessions: %{}
    }
  end

  defp socket(view) do
    render(view)
    :sys.get_state(view.pid).socket
  end

  defp chat(view), do: socket(view).assigns.react_chat
  defp request_count(h), do: Agent.get(h.counter, &length(&1.provider_requests))

  defp user_texts(request),
    do: for(m <- request["messages"], m["role"] == "user", do: wire_text(m["content"]))

  defp wire_text(text) when is_binary(text), do: text
  defp wire_text(blocks), do: Enum.map_join(blocks, "", &Map.get(&1, "text", ""))

  defp await_event(id, event_id, phase) do
    assert {:ok, event} =
             wait_for(fn ->
               with {:ok, rows} <- PendingInputStore.list_result(id),
                    event when not is_nil(event) <- Enum.find(rows, &(&1.id == event_id)),
                    true <- event.event["phase"] == phase,
                    do: {:ok, event},
                    else: (_ -> :retry)
             end)

    event
  end

  defp await_idle(id) do
    assert {:ok, :idle} =
             wait_for(fn ->
               case Worker.public_status(id) do
                 {:ok, %{runtime: %{active: false, phase: "idle"}}} -> {:ok, :idle}
                 _ -> :retry
               end
             end)
  end
end
