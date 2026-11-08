defmodule Synapsis.MessageEventReplyFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.{Message, Part.Text, Session.Store}

  setup do
    assert :ok = Store.ensure_started()
    session_id = Ecto.UUID.generate()
    on_exit(fn -> Store.delete_session(session_id) end)
    %{session_id: session_id}
  end

  test "assistant event presentation provenance roundtrips through real durable turns without replacing raw text",
       ctx do
    stamp = %{
      "version" => 1,
      "policy" => "manual_event_message",
      "occurrence_id" => Ecto.UUID.generate()
    }

    raw = "HEARTBEAT_OK  完成\n\n🙂"

    message =
      %Message{
        id: Ecto.UUID.generate(),
        session_id: ctx.session_id,
        role: "assistant",
        token_count: 17,
        inserted_at: ~U[2026-10-28 02:00:00.000000Z],
        parts: [%Text{content: raw}]
      }
      |> Map.put(:reply_presentation, stamp)

    encoded = Message.encode(message)
    assert encoded[:reply_presentation] == stamp
    assert encoded.parts == [%{type: "text", text: raw}]
    assert :ok = Store.commit_turn(ctx.session_id, 0, encoded, %{turn_count: 1})
    assert {:ok, ^encoded} = Store.get_turn(ctx.session_id, 0)
    assert [reloaded] = Message.list_by_session(ctx.session_id)
    assert Map.get(reloaded, :reply_presentation) == stamp
    assert reloaded == message
    assert Message.encode(reloaded) == encoded
    assert [^reloaded] = Message.list_recent_by_session(ctx.session_id, 1)
  end

  test "string keyed stored provenance decodes with the original assistant identity and text",
       ctx do
    id = Ecto.UUID.generate()

    stamp = %{
      "version" => 1,
      "policy" => "manual_event_message",
      "occurrence_id" => Ecto.UUID.generate()
    }

    encoded = %{
      "id" => id,
      "role" => "assistant",
      "token_count" => 3,
      "reply_presentation" => stamp,
      "parts" => [%{type: "text", text: "**HEARTBEAT_OK**"}]
    }

    assert :ok = Store.commit_turn(ctx.session_id, 0, encoded, %{turn_count: 1})
    assert [reloaded] = Message.list_by_session(ctx.session_id)
    assert reloaded.id == id
    assert reloaded.role == "assistant"
    assert Map.get(reloaded, :reply_presentation) == stamp
    assert reloaded.parts == [%Text{content: "**HEARTBEAT_OK**"}]
    assert reloaded.token_count == 3
  end

  test "ordinary messages retain the existing exact durable shape", ctx do
    message = %Message{
      id: Ecto.UUID.generate(),
      session_id: ctx.session_id,
      role: "assistant",
      inserted_at: ~U[2026-10-28 02:00:00.000000Z],
      parts: [%Text{content: "HEARTBEAT_OK ordinary"}]
    }

    expected = %{
      id: message.id,
      role: "assistant",
      token_count: 0,
      inserted_at: message.inserted_at,
      parts: [%{type: "text", text: "HEARTBEAT_OK ordinary"}]
    }

    assert Message.encode(message) == expected
    assert :ok = Store.commit_turn(ctx.session_id, 0, expected, %{turn_count: 1})
    assert [^message] = Message.list_by_session(ctx.session_id)
    assert Map.get(message, :reply_presentation) == nil
  end
end
