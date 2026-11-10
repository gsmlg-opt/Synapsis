defmodule Synapsis.MessageTest do
  use Synapsis.DataCase

  alias Synapsis.Message

  # ADR-006 C4: Message is an embedded_schema; durable storage is Concord turns
  # (see Synapsis.Session.Store). These tests cover changeset validation and the
  # `{:array, Synapsis.Part}` casting via apply_changes (no Repo).
  setup do
    %{session: %{id: Ecto.UUID.generate()}}
  end

  defp build(attrs) do
    %Message{} |> Message.changeset(attrs) |> Ecto.Changeset.apply_changes()
  end

  describe "changeset/2" do
    test "valid with required fields", %{session: session} do
      cs = %Message{} |> Message.changeset(%{role: "user", session_id: session.id})
      assert cs.valid?
    end

    test "invalid without role", %{session: session} do
      cs = %Message{} |> Message.changeset(%{session_id: session.id})
      refute cs.valid?
      assert %{role: ["can't be blank"]} = errors_on(cs)
    end

    test "invalid without session_id" do
      cs = %Message{} |> Message.changeset(%{role: "user"})
      refute cs.valid?
      assert %{session_id: ["can't be blank"]} = errors_on(cs)
    end

    test "validates role inclusion", %{session: session} do
      cs = %Message{} |> Message.changeset(%{role: "invalid_role", session_id: session.id})
      refute cs.valid?
      assert %{role: [_]} = errors_on(cs)
    end

    test "allows valid roles", %{session: session} do
      for role <- ~w(user assistant system) do
        cs = %Message{} |> Message.changeset(%{role: role, session_id: session.id})
        assert cs.valid?, "Expected role #{role} to be valid"
      end
    end

    test "sets defaults", %{session: session} do
      cs = %Message{} |> Message.changeset(%{role: "user", session_id: session.id})
      assert get_field(cs, :parts) == []
      assert get_field(cs, :token_count) == 0
    end
  end

  describe "role validation edge cases" do
    test "rejects empty string as role", %{session: session} do
      cs = %Message{} |> Message.changeset(%{role: "", session_id: session.id})
      refute cs.valid?
      assert %{role: [_]} = errors_on(cs)
    end

    test "rejects capitalized role", %{session: session} do
      cs = %Message{} |> Message.changeset(%{role: "User", session_id: session.id})
      refute cs.valid?
      assert %{role: [_]} = errors_on(cs)
    end

    test "rejects role with whitespace", %{session: session} do
      cs = %Message{} |> Message.changeset(%{role: " user ", session_id: session.id})
      refute cs.valid?
      assert %{role: [_]} = errors_on(cs)
    end

    test "rejects tool as role", %{session: session} do
      cs = %Message{} |> Message.changeset(%{role: "tool", session_id: session.id})
      refute cs.valid?
      assert %{role: [_]} = errors_on(cs)
    end

    test "rejects function as role", %{session: session} do
      cs = %Message{} |> Message.changeset(%{role: "function", session_id: session.id})
      refute cs.valid?
      assert %{role: [_]} = errors_on(cs)
    end
  end

  describe "token_count validation" do
    test "accepts zero token_count", %{session: session} do
      cs =
        %Message{} |> Message.changeset(%{role: "user", session_id: session.id, token_count: 0})

      assert cs.valid?
    end

    test "accepts positive token_count", %{session: session} do
      cs =
        %Message{}
        |> Message.changeset(%{role: "user", session_id: session.id, token_count: 5000})

      assert cs.valid?
    end

    test "token_count defaults to zero", %{session: session} do
      cs = %Message{} |> Message.changeset(%{role: "user", session_id: session.id})
      assert get_field(cs, :token_count) == 0
    end

    test "casts token_count correctly", %{session: session} do
      msg = build(%{role: "user", session_id: session.id, token_count: 42})
      assert msg.token_count == 42
    end
  end

  describe "parts field with multiple part types" do
    test "casts text part", %{session: session} do
      parts = [%{"type" => "text", "content" => "Hello world"}]
      msg = build(%{role: "user", session_id: session.id, parts: parts})
      assert [%Synapsis.Part.Text{content: "Hello world"}] = msg.parts
    end

    test "casts tool_use part", %{session: session} do
      parts = [
        %{
          "type" => "tool_use",
          "tool" => "bash",
          "tool_use_id" => "tu_123",
          "input" => %{"command" => "ls -la"},
          "status" => "pending"
        }
      ]

      msg = build(%{role: "assistant", session_id: session.id, parts: parts})

      assert [
               %Synapsis.Part.ToolUse{
                 tool: "bash",
                 tool_use_id: "tu_123",
                 input: %{"command" => "ls -la"},
                 status: :pending
               }
             ] = msg.parts
    end

    test "casts tool_result part", %{session: session} do
      parts = [
        %{
          "type" => "tool_result",
          "tool_use_id" => "tu_123",
          "content" => "file1.ex\nfile2.ex",
          "is_error" => false
        }
      ]

      msg = build(%{role: "user", session_id: session.id, parts: parts})

      assert [
               %Synapsis.Part.ToolResult{
                 tool_use_id: "tu_123",
                 content: "file1.ex\nfile2.ex",
                 is_error: false
               }
             ] = msg.parts
    end

    test "casts reasoning part", %{session: session} do
      parts = [%{"type" => "reasoning", "content" => "Let me think about this..."}]
      msg = build(%{role: "assistant", session_id: session.id, parts: parts})
      assert [%Synapsis.Part.Reasoning{content: "Let me think about this..."}] = msg.parts
    end

    test "casts multiple mixed part types", %{session: session} do
      parts = [
        %{"type" => "text", "content" => "I'll help with that."},
        %{
          "type" => "tool_use",
          "tool" => "file_read",
          "tool_use_id" => "tu_456",
          "input" => %{"path" => "/tmp/test.ex"},
          "status" => "completed"
        },
        %{"type" => "reasoning", "content" => "The file contains..."}
      ]

      msg = build(%{role: "assistant", session_id: session.id, parts: parts})

      assert length(msg.parts) == 3
      assert %Synapsis.Part.Text{content: "I'll help with that."} = Enum.at(msg.parts, 0)
      assert %Synapsis.Part.ToolUse{tool: "file_read"} = Enum.at(msg.parts, 1)
      assert %Synapsis.Part.Reasoning{content: "The file contains..."} = Enum.at(msg.parts, 2)
    end

    test "casts agent part", %{session: session} do
      parts = [%{"type" => "agent", "agent" => "plan", "message" => "Switching to plan mode."}]
      msg = build(%{role: "assistant", session_id: session.id, parts: parts})
      assert [%Synapsis.Part.Agent{agent: "plan", message: "Switching to plan mode."}] = msg.parts
    end

    test "empty parts list casts correctly", %{session: session} do
      msg = build(%{role: "user", session_id: session.id, parts: []})
      assert msg.parts == []
    end

    test "tool_result with is_error true casts", %{session: session} do
      parts = [
        %{
          "type" => "tool_result",
          "tool_use_id" => "tu_err",
          "content" => "Permission denied",
          "is_error" => true
        }
      ]

      msg = build(%{role: "user", session_id: session.id, parts: parts})
      assert [%Synapsis.Part.ToolResult{is_error: true, content: "Permission denied"}] = msg.parts
    end
  end

  describe "Concord turn round-trip" do
    test "structured tool projection survives a new turn without rewriting legacy history", %{
      session: session
    } do
      alias Synapsis.{Part.ToolResult, Session.Store}
      on_exit(fn -> Store.delete_session(session.id) end)

      legacy = %{
        id: Ecto.UUID.generate(),
        role: "user",
        token_count: 0,
        parts: [
          %{type: "tool_result", tool_use_id: "old-call", content: "old text", is_error: false}
        ]
      }

      projection = %{
        "version" => 1,
        "result" => %{
          "content" => [
            %{"type" => "text", "text" => "first"},
            %{"type" => "image", "mimeType" => "image/png", "data" => "aW1hZ2U="},
            %{"type" => "text", "text" => "last"}
          ],
          "structured" => %{"count" => 1},
          "is_error" => false
        }
      }

      part =
        %ToolResult{tool_use_id: "new-call", content: "first\nlast"}
        |> Map.put(:projection, projection)

      message = %Message{
        id: Ecto.UUID.generate(),
        session_id: session.id,
        role: "user",
        parts: [part]
      }

      assert :ok = Store.commit_turn(session.id, 0, legacy, %{turn_count: 1})
      assert :ok = Store.commit_turn(session.id, 1, Message.encode(message), %{turn_count: 2})
      assert {:ok, ^legacy} = Store.get_turn(session.id, 0)

      assert [%Message{parts: [old]}, %Message{parts: [current]}] =
               Message.list_by_session(session.id)

      assert old.content == "old text"
      assert Map.get(old, :projection) == nil
      assert current.tool_use_id == "new-call"
      assert current.content == "first\nlast"
      assert Map.get(current, :projection) == projection
      assert [%Message{parts: [^current]}] = Message.list_recent_by_session(session.id, 1)

      encoded_legacy = Message.encode(%Message{role: "user", parts: [old]})
      refute Map.has_key?(hd(encoded_legacy.parts), :projection)
    end

    test "append and list_by_session round-trips role and token_count", %{session: session} do
      {:ok, _msg} = Message.append(session.id, %{role: "user", token_count: 10})

      assert [%Message{role: "user", token_count: 10, session_id: sid}] =
               Message.list_by_session(session.id)

      assert sid == session.id
    end

    test "list_by_session is empty for an unknown session" do
      assert Message.list_by_session(Ecto.UUID.generate()) == []
    end

    test "list_recent_by_session decodes only the latest messages", %{session: session} do
      assert :ok = Synapsis.Session.Store.put_meta(session.id, %{id: session.id, turn_count: 0})

      messages =
        for n <- 1..30 do
          %Message{
            id: Ecto.UUID.generate(),
            role: "assistant",
            session_id: session.id,
            inserted_at: DateTime.utc_now(),
            parts: [%Synapsis.Part.Text{content: "message #{n}"}]
          }
        end

      assert :ok = Message.persist_list(session.id, messages)

      recent = Message.list_recent_by_session(session.id, 10)

      assert Enum.map(recent, fn message ->
               assert [%Synapsis.Part.Text{content: content}] = message.parts
               content
             end) == Enum.map(21..30, &"message #{&1}")
    end
  end
end
