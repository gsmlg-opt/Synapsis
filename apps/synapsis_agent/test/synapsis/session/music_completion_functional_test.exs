defmodule Synapsis.Session.MusicCompletionFunctionalTest do
  use ExUnit.Case, async: false

  import Synapsis.Agent.DaemonCase, only: [wait_for: 1]

  alias Synapsis.Agent.TestSupport.DeterministicProvider
  alias Synapsis.Part.{Audio, Text}
  alias Synapsis.Session.{DynamicSupervisor, PendingInputStore, Store, Worker}
  alias Synapsis.{Message, Sessions}

  @moduletag :tmp_dir
  @original "Original held music turn"
  @result "  Music ready 雪 😀\nHEARTBEAT_OK  "
  @follow_up " \uFEFFMusic completion café\n  Keep these spaces  \n "
  @replay "Recall the delivered music"

  test "busy music completion is applied once in order and ordinary history reload retains audio and followup",
       ctx do
    h = fixture(ctx.tmp_dir)
    id = h.session.id
    tag = h.tag
    attrs = completion(h)
    assert :ok = Worker.send_message(id, @original)
    assert_receive {:music_request, ^tag, 0, original, original_handler}, 10_000
    assert wire_messages(original) === [{"user", @original}]

    assert {:ok,
            %{
              event_id: event_id,
              duplicate: false,
              phase: "staged",
              status: "queued",
              application: nil
            }} =
             Sessions.stage_music_completion(id, attrs)

    assert event_id === attrs.id
    assert {:ok, [staged]} = PendingInputStore.list_result(id)
    assert staged.id === attrs.id
    assert staged.content === @follow_up
    assert staged.input_provenance === provenance(h, attrs)
    assert staged.event["completion"]["source"] === "music_generate"
    assert staged.event["completion"]["type"] === "task_completion"
    assert staged.event["completion"]["status"] === "ok"
    assert staged.event["target_agent_id"] === h.agent.id
    assert {:ok, _owner_id} = Ecto.UUID.cast(staged.event["owner_id"])
    assert {:ok, pending_before} = Store.read_pending_inputs(id)

    assert Sessions.stage_music_completion(id, attrs) ===
             {:ok,
              %{
                event_id: attrs.id,
                duplicate: true,
                phase: "staged",
                status: "queued",
                application: nil
              }}

    assert Store.read_pending_inputs(id) === {:ok, pending_before}
    assert {:ok, [only_original]} = Store.list_turns(id)
    assert only_original.role === "user"
    assert request_count(h) === 1

    send(original_handler, :continue_music)
    assert_receive {:music_request, ^tag, 1, following, following_handler}, 10_000

    [
      {"user", @original},
      {"assistant", "original completed"},
      {"assistant", artifact_text},
      {"user", @follow_up}
    ] =
      wire_messages(following)

    assert artifact_text =~ @result
    [first_audio, second_audio] = attrs.audio_parts
    first_summary = expected_summary(first_audio)
    second_summary = expected_summary(second_audio)
    assert artifact_text =~ first_summary
    assert artifact_text =~ second_summary
    {result_offset, _} = :binary.match(artifact_text, @result)
    {first_offset, _} = :binary.match(artifact_text, first_summary)
    {second_offset, _} = :binary.match(artifact_text, second_summary)
    assert result_offset < first_offset
    assert first_offset < second_offset

    assert {:ok, [_, _, artifact_turn, follow_up_turn]} = Store.list_turns(id)
    assert artifact_turn.id === attrs.artifact_message_id

    assert artifact_turn.parts === [
             %{type: "text", text: @result},
             %{
               type: "audio",
               descriptor: first_audio.descriptor,
               delivery: first_audio.delivery,
               name: first_audio.name
             },
             %{
               type: "audio",
               descriptor: second_audio.descriptor,
               delivery: second_audio.delivery,
               name: second_audio.name
             }
           ]

    assert artifact_turn.input_provenance === provenance(h, attrs)
    assert follow_up_turn.id === attrs.id
    assert follow_up_turn.parts === [%{type: "text", text: @follow_up}]
    assert follow_up_turn.input_provenance === provenance(h, attrs)
    assert follow_up_turn.internal_turn_source === "event"
    assert Map.get(artifact_turn, :reply_presentation) === nil
    assert Map.get(follow_up_turn, :reply_presentation) === nil
    started = await_event(id, attrs.id, "started")

    application = %{"start_n" => 2, "message_ids" => [attrs.artifact_message_id, attrs.id]}
    assert started.event["application"] === application
    send(following_handler, :continue_music)
    completed = await_event(id, attrs.id, "completed")
    await_idle(id)
    assert completed.status === "consumed"
    assert completed.event["application"] === application
    assert request_count(h) === 2

    assert {:ok, before_duplicate} = Store.list_turns(id)
    assert length(before_duplicate) === 5
    terminal = List.last(before_duplicate)
    assert terminal.role === "assistant"
    assert terminal.parts === [%{type: "text", text: "HEARTBEAT_OK"}]
    assert Map.get(terminal, :reply_presentation) === nil
    assert {:ok, completed_snapshot} = Store.read_pending_inputs(id)

    assert Sessions.stage_music_completion(id, attrs) ===
             {:ok,
              %{
                event_id: attrs.id,
                duplicate: true,
                phase: "completed",
                status: "consumed",
                application: application
              }}

    assert Store.read_pending_inputs(id) === {:ok, completed_snapshot}
    assert Store.list_turns(id) === {:ok, before_duplicate}
    await_idle(id)
    assert request_count(h) === 2

    durable = Message.list_by_session(id)
    assert Enum.map(durable, & &1.id) === Enum.map(before_duplicate, & &1.id)
    assert Enum.at(durable, 2).parts === [%Text{content: @result} | attrs.audio_parts]
    assert Enum.at(durable, 3).parts === [%Text{content: @follow_up}]
    assert Enum.at(durable, 3).internal_turn_source === "event"
    assert List.last(durable).parts === [%Text{content: "HEARTBEAT_OK"}]

    assert :ok = DynamicSupervisor.stop_session(id)
    assert :ok = Sessions.ensure_running(id)
    await_idle(id)
    assert Message.list_by_session(id) === durable
    assert {:ok, [^completed]} = PendingInputStore.list_result(id)
    assert request_count(h) === 2
    assert :ok = Worker.send_message(id, @replay)
    assert_receive {:music_request, ^tag, 2, replay, _handler}, 10_000

    assert wire_messages(replay) ===
             wire_messages(following) ++ [{"assistant", "HEARTBEAT_OK"}, {"user", @replay}]

    await_idle(id)
    assert request_count(h) === 3
    assert {:ok, after_reload} = Store.list_turns(id)
    assert Enum.take(after_reload, length(before_duplicate)) === before_duplicate
    assert {:ok, [^completed]} = PendingInputStore.list_result(id)
  end

  defp fixture(root) do
    owner = self()
    http = Gaoxy.Test.open()
    tag = Ecto.UUID.generate()
    name = "music-completion-#{tag}"
    requests = start_supervised!({Agent, fn -> [] end}, id: tag)

    assert :ok =
             Synapsis.Provider.Registry.register(name, %{
               type: "openai",
               api_key: "test-key",
               base_url: String.trim_trailing(Gaoxy.Test.url(http), "/")
             })

    assert {:ok, agent} =
             Synapsis.AgentConfigs.create(%{
               name: name,
               provider: name,
               model: "music-model-#{tag}",
               tools: [],
               tool_contract_version: 1,
               config: %{"workspace_path" => root}
             })

    Gaoxy.Test.stub(http, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      handler = self()

      index =
        Agent.get_and_update(requests, fn entries ->
          {length(entries), entries ++ [%{request: request, handler: handler}]}
        end)

      send(owner, {:music_request, tag, index, request, handler})

      if index in [0, 1] do
        receive do
          :continue_music -> :ok
        after
          20_000 -> raise "music completion successful handshake timed out"
        end
      end

      text =
        case index do
          0 -> "original completed"
          1 -> "HEARTBEAT_OK"
          _ -> "music history recalled"
        end

      DeterministicProvider.send_sse(conn, [
        DeterministicProvider.text_chunk(text),
        DeterministicProvider.finish_chunk("stop")
      ])
    end)

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
      if Process.alive?(requests) do
        for entry <- Agent.get(requests, & &1), do: send(entry.handler, :continue_music)
      end

      Sessions.delete(session.id)
      Synapsis.AgentConfigs.delete(agent)
      Synapsis.Provider.Registry.unregister(name)
    end)

    %{session: session, agent: agent, requests: requests, tag: tag}
  end

  defp completion(h) do
    %{
      id: Ecto.UUID.generate(),
      artifact_message_id: Ecto.UUID.generate(),
      agent_id: h.agent.id,
      task_id: Ecto.UUID.generate(),
      result: @result,
      follow_up: @follow_up,
      audio_parts: [
        audio(h.session.id, "a", "First track 雪"),
        audio(h.session.id, "b", "Second track 😀")
      ]
    }
  end

  defp audio(session_id, digit, name) do
    sha = String.duplicate(digit, 64)

    %Audio{
      descriptor: %{
        "uri" => "synapsis-media://audio/" <> sha <> ".wav",
        "sha256" => sha,
        "byte_size" => 48,
        "mime_type" => "audio/wav",
        "format" => "wav"
      },
      delivery: %{"version" => 1, "session_id" => session_id, "id" => Ecto.UUID.generate()},
      name: name
    }
  end

  defp expected_summary(audio) do
    "Delivered audio: " <>
      audio.name <>
      "\nURI: " <>
      audio.descriptor["uri"] <>
      "\nMIME: audio/wav\nDelivery: v1 " <>
      audio.delivery["session_id"] <> "/" <> audio.delivery["id"]
  end

  defp provenance(h, attrs) do
    %{
      "kind" => "inter_session",
      "event_type" => "task_completion",
      "source_tool" => "music_generate",
      "source_session_key" => "music_generate:" <> attrs.task_id,
      "follow_up_id" => "music_generate:" <> attrs.task_id <> ":ok:agent-loop",
      "source_session_id" => h.session.id,
      "source_agent_id" => h.agent.id,
      "task_id" => attrs.task_id,
      "announce_id" => "music_generate:" <> attrs.task_id <> ":ok"
    }
  end

  defp await_event(id, event_id, phase) do
    assert {:ok, event} =
             wait_for(fn ->
               with {:ok, inputs} <- PendingInputStore.list_result(id),
                    event when not is_nil(event) <- Enum.find(inputs, &(&1.id == event_id)),
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

  defp request_count(h), do: Agent.get(h.requests, &length/1)

  defp wire_messages(request) do
    request["messages"]
    |> Enum.reject(&(&1["role"] == "system"))
    |> Enum.map(fn message ->
      text =
        case message["content"] do
          text when is_binary(text) -> text
          blocks when is_list(blocks) -> Enum.map_join(blocks, "", &Map.get(&1, "text", ""))
        end

      {message["role"], text}
    end)
  end
end
