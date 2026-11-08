defmodule Synapsis.Session.MusicCompletionStoreFunctionalTest do
  use ExUnit.Case, async: false

  alias Concord.KV.Record
  alias Synapsis.{Message, Part}
  alias Synapsis.Session.{PendingInputStore, Store}

  setup do
    assert :ok = Store.ensure_started()
    session_id = Ecto.UUID.generate()
    on_exit(fn -> Store.delete_session(session_id) end)

    %{session_id: session_id, owner_id: Ecto.UUID.generate(), agent_id: Ecto.UUID.generate()}
  end

  test "successful completion retains exact text ordered portable audio and original scope",
       ctx do
    attrs = completion(ctx)

    assert {:ok, %{input: input, inserted: true}} =
             PendingInputStore.append_music_completion(ctx.session_id, attrs)

    assert %PendingInputStore{} = input
    assert input.id === attrs.id
    assert input.session_id === ctx.session_id
    assert input.kind === "system_event"
    assert input.status === "queued"
    assert input.content === attrs.follow_up
    assert input.image_parts === []
    assert input.input_provenance === provenance(ctx, attrs)

    assert input.event === %{
             "owner_id" => ctx.owner_id,
             "target_agent_id" => ctx.agent_id,
             "mode" => "now",
             "phase" => "staged",
             "completion" => envelope(attrs)
           }

    assert {:ok, ^input} =
             in_fresh_process(fn ->
               PendingInputStore.lookup_music_completion(
                 ctx.session_id,
                 ctx.agent_id,
                 attrs.task_id
               )
             end)

    assert {:ok, [^input]} = PendingInputStore.list_result(ctx.session_id)
    assert {:ok, {:present, [raw], _revision}} = Store.read_pending_inputs(ctx.session_id)
    assert Jason.decode!(Jason.encode!(raw))["event"]["completion"] === envelope(attrs)
  end

  test "an exact queued repeat returns the original row without a storage write", ctx do
    attrs = completion(ctx)

    assert {:ok, %{input: first, inserted: true}} =
             PendingInputStore.append_music_completion(ctx.session_id, attrs)

    assert {:ok, before} = Store.read_pending_inputs(ctx.session_id)
    before_revision = revision()

    assert PendingInputStore.append_music_completion(ctx.session_id, attrs) ===
             {:ok, %{input: first, inserted: false}}

    assert Store.read_pending_inputs(ctx.session_id) === {:ok, before}
    assert revision() === before_revision
    assert {:ok, [^first]} = PendingInputStore.list_result(ctx.session_id)
    assert {:ok, []} = Store.list_turns(ctx.session_id)
  end

  test "reserved completion publishes both turns metadata and application in one revision and terminal repeat reads back",
       ctx do
    attrs = completion(ctx)
    before_meta = %{title: "Original music session 雪", turn_count: 1, opaque: {:kept, <<0, 255>>}}
    after_meta = %{before_meta | turn_count: 3}

    original_turn = %{
      id: Ecto.UUID.generate(),
      role: "user",
      parts: [%{type: "text", text: "original"}]
    }

    assert :ok = Store.commit_turn(ctx.session_id, 0, original_turn, before_meta)

    assert {:ok, %{input: input, inserted: true}} =
             PendingInputStore.append_music_completion(ctx.session_id, attrs)

    assert {:ok, later} =
             PendingInputStore.append_prompt(ctx.session_id, "later ordinary prompt", [])

    assert {:ok, ^input} = PendingInputStore.take_next_turn(ctx.session_id, ctx.owner_id)
    turns = completion_turns(ctx, attrs)
    before_revision = revision()

    assert :ok =
             PendingInputStore.apply_music_completion(
               ctx.session_id,
               attrs.id,
               ctx.owner_id,
               1,
               turns,
               before_meta,
               after_meta
             )

    published = revision()
    assert published === before_revision + 1
    assert Store.list_turns(ctx.session_id) === {:ok, [original_turn | turns]}
    assert Store.get_meta(ctx.session_id) === {:ok, after_meta}
    assert {:ok, [applied, ^later]} = PendingInputStore.list_result(ctx.session_id)
    assert applied.status === "inflight"
    assert applied.event["phase"] === "staged"
    assert applied.event["completion"] === envelope(attrs)

    assert applied.event["application"] === %{
             "start_n" => 1,
             "message_ids" => [attrs.artifact_message_id, attrs.id]
           }

    for key <- [
          Store.turn_key(ctx.session_id, 1),
          Store.turn_key(ctx.session_id, 2),
          Store.meta_key(ctx.session_id),
          Store.value_key(ctx.session_id, "pending_inputs")
        ] do
      assert %Record{mod_revision: ^published} = stored_record(key)
    end

    assert [artifact, follow_up] = Enum.drop(Message.list_by_session(ctx.session_id), 1)
    assert artifact.id === attrs.artifact_message_id
    assert artifact.parts === [%Part.Text{content: attrs.result} | attrs.audio_parts]
    assert artifact.input_provenance === provenance(ctx, attrs)
    assert follow_up.id === attrs.id
    assert follow_up.parts === [%Part.Text{content: attrs.follow_up}]
    assert follow_up.internal_turn_source === "event"
    assert follow_up.input_provenance === provenance(ctx, attrs)

    run_id = Ecto.UUID.generate()
    assert :ok = PendingInputStore.start_event(ctx.session_id, attrs.id, ctx.owner_id, run_id)

    assert :ok =
             PendingInputStore.finish_event(ctx.session_id, attrs.id, ctx.owner_id, :completed)

    assert {:ok, [completed, ^later]} = PendingInputStore.list_result(ctx.session_id)
    assert completed.status === "consumed"
    assert completed.event["phase"] === "completed"
    assert completed.event["run_id"] === run_id
    assert completed.event["application"] === applied.event["application"]
    assert {:ok, snapshot} = Store.read_pending_inputs(ctx.session_id)
    terminal_revision = revision()

    assert PendingInputStore.append_music_completion(ctx.session_id, attrs) ===
             {:ok, %{input: completed, inserted: false}}

    assert PendingInputStore.lookup_music_completion(ctx.session_id, ctx.agent_id, attrs.task_id) ===
             {:ok, completed}

    assert Store.read_pending_inputs(ctx.session_id) === {:ok, snapshot}
    assert revision() === terminal_revision
    assert Store.list_turns(ctx.session_id) === {:ok, [original_turn | turns]}
  end

  defp completion(ctx) do
    %{
      id: Ecto.UUID.generate(),
      artifact_message_id: Ecto.UUID.generate(),
      owner_id: ctx.owner_id,
      agent_id: ctx.agent_id,
      task_id: Ecto.UUID.generate(),
      result: "  Generated music 雪 😀\nHEARTBEAT_OK  ",
      follow_up: " \uFEFFMusic ready café\n  Preserve this body  \n ",
      audio_parts: [
        audio(ctx.session_id, "a", "First track 雪"),
        audio(ctx.session_id, "b", "Second track 😀")
      ]
    }
  end

  defp audio(session_id, digit, name) do
    sha = String.duplicate(digit, 64)

    %Part.Audio{
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

  defp provenance(ctx, attrs) do
    %{
      "kind" => "inter_session",
      "event_type" => "task_completion",
      "source_session_key" => "music_generate:" <> attrs.task_id,
      "follow_up_id" => "music_generate:" <> attrs.task_id <> ":ok:agent-loop",
      "source_tool" => "music_generate",
      "source_session_id" => ctx.session_id,
      "source_agent_id" => ctx.agent_id,
      "task_id" => attrs.task_id,
      "announce_id" => "music_generate:" <> attrs.task_id <> ":ok"
    }
  end

  defp envelope(attrs) do
    %{
      "version" => 1,
      "type" => "task_completion",
      "source" => "music_generate",
      "status" => "ok",
      "source_session_key" => "music_generate:" <> attrs.task_id,
      "follow_up_id" => "music_generate:" <> attrs.task_id <> ":ok:agent-loop",
      "announce_id" => "music_generate:" <> attrs.task_id <> ":ok",
      "task_id" => attrs.task_id,
      "artifact_message_id" => attrs.artifact_message_id,
      "result" => attrs.result,
      "audio_parts" => Enum.map(attrs.audio_parts, &portable_audio/1)
    }
  end

  defp portable_audio(audio) do
    %{
      "type" => "audio",
      "descriptor" => audio.descriptor,
      "delivery" => audio.delivery,
      "name" => audio.name
    }
  end

  defp completion_turns(ctx, attrs) do
    [
      %Message{
        id: attrs.artifact_message_id,
        session_id: ctx.session_id,
        role: "assistant",
        input_provenance: provenance(ctx, attrs),
        parts: [%Part.Text{content: attrs.result} | attrs.audio_parts]
      },
      %Message{
        id: attrs.id,
        session_id: ctx.session_id,
        role: "user",
        input_provenance: provenance(ctx, attrs),
        internal_turn_source: "event",
        parts: [%Part.Text{content: attrs.follow_up}]
      }
    ]
    |> Enum.map(&Message.encode/1)
  end

  defp stored_record(key) do
    assert {:ok, %Record{} = record} =
             Concord.KV.get(key, engine: :turso, metadata: true, timeout: 5_000)

    record
  end

  defp revision do
    assert {:ok, revision} = Concord.Turso.revision(timeout: 5_000)
    revision
  end

  defp in_fresh_process(fun), do: Task.async(fun) |> Task.await(10_000)
end
