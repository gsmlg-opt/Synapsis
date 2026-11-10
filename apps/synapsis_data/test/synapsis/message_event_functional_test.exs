defmodule Synapsis.MessageEventFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.{Message, Part.Text, Session.Store}

  setup do
    assert :ok = Store.ensure_started()
    session_id = Ecto.UUID.generate()
    on_exit(fn -> Store.delete_session(session_id) end)
    %{session_id: session_id}
  end

  test "event provenance survives actual turn commit read and Message decoding", ctx do
    event_id = Ecto.UUID.generate()

    provenance = %{
      "kind" => "internal_system",
      "source_tool" => "cron",
      "source_session_id" => Ecto.UUID.generate(),
      "source_agent_id" => Ecto.UUID.generate()
    }

    message =
      struct(Message,
        id: event_id,
        session_id: ctx.session_id,
        role: "user",
        parts: [%Text{content: "check the queue"}],
        input_provenance: provenance,
        internal_turn_source: "event"
      )

    encoded = Message.encode(message)
    assert encoded[:input_provenance] == provenance
    assert encoded[:internal_turn_source] == "event"
    assert :ok = Store.commit_turn(ctx.session_id, 0, encoded, %{turn_count: 1})
    assert {:ok, ^encoded} = Store.get_turn(ctx.session_id, 0)
    assert [reloaded] = Message.list_by_session(ctx.session_id)
    assert reloaded.id == event_id
    assert reloaded.role == "user"
    assert reloaded.parts == [%Text{content: "check the queue"}]
    assert Map.get(reloaded, :input_provenance) == provenance
    assert Map.get(reloaded, :internal_turn_source) == "event"
    assert [^reloaded] = Message.list_recent_by_session(ctx.session_id, 1)
  end

  test "ordinary messages retain the existing durable shape with optional metadata absent", ctx do
    message = %Message{
      id: Ecto.UUID.generate(),
      session_id: ctx.session_id,
      role: "user",
      inserted_at: ~U[2026-10-28 01:00:00.000000Z],
      parts: [%Text{content: "ordinary input"}]
    }

    expected = %{
      id: message.id,
      role: "user",
      token_count: 0,
      inserted_at: message.inserted_at,
      parts: [%{type: "text", text: "ordinary input"}]
    }

    assert Message.encode(message) == expected
    assert :ok = Store.commit_turn(ctx.session_id, 0, expected, %{turn_count: 1})
    assert {:ok, ^expected} = Store.get_turn(ctx.session_id, 0)
    assert [reloaded] = Message.list_by_session(ctx.session_id)
    assert reloaded == message
    assert Map.get(reloaded, :input_provenance) == nil
    assert Map.get(reloaded, :internal_turn_source) == nil
    assert Message.encode(reloaded) == expected
  end
end
