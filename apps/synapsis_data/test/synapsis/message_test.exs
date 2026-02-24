defmodule Synapsis.MessageTest do
  use Synapsis.DataCase

  alias Synapsis.{Message, Session, Project, Repo}

  setup do
    {:ok, project} =
      %Project{}
      |> Project.changeset(%{
        path: "/tmp/msg_test_#{:rand.uniform(100_000)}",
        slug: "msg-test-#{:rand.uniform(100_000)}"
      })
      |> Repo.insert()

    {:ok, session} =
      %Session{}
      |> Session.changeset(%{provider: "test", model: "test", project_id: project.id})
      |> Repo.insert()

    %{session: session}
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
      cs = %Message{} |> Message.changeset(%{role: "user", session_id: session.id, token_count: 0})
      assert cs.valid?
    end

    test "accepts positive token_count", %{session: session} do
      cs = %Message{} |> Message.changeset(%{role: "user", session_id: session.id, token_count: 5000})
      assert cs.valid?
    end

    test "token_count defaults to zero", %{session: session} do
      cs = %Message{} |> Message.changeset(%{role: "user", session_id: session.id})
      assert get_field(cs, :token_count) == 0
    end

    test "persists token_count correctly", %{session: session} do
      {:ok, msg} =
        %Message{}
        |> Message.changeset(%{role: "user", session_id: session.id, token_count: 42})
        |> Repo.insert()

      found = Repo.get!(Message, msg.id)
      assert found.token_count == 42
    end
  end

  describe "parts field with multiple part types" do
    test "stores and retrieves text part", %{session: session} do
      parts = [%{"type" => "text", "content" => "Hello world"}]

      {:ok, msg} =
        %Message{}
        |> Message.changeset(%{role: "user", session_id: session.id, parts: parts})
        |> Repo.insert()

      found = Repo.get!(Message, msg.id)
      assert [%Synapsis.Part.Text{content: "Hello world"}] = found.parts
    end

    test "stores and retrieves tool_use part", %{session: session} do
      parts = [
        %{
          "type" => "tool_use",
          "tool" => "bash",
          "tool_use_id" => "tu_123",
          "input" => %{"command" => "ls -la"},
          "status" => "pending"
        }
      ]

      {:ok, msg} =
        %Message{}
        |> Message.changeset(%{role: "assistant", session_id: session.id, parts: parts})
        |> Repo.insert()

      found = Repo.get!(Message, msg.id)
      assert [%Synapsis.Part.ToolUse{tool: "bash", tool_use_id: "tu_123", input: %{"command" => "ls -la"}, status: :pending}] = found.parts
    end

    test "stores and retrieves tool_result part", %{session: session} do
      parts = [
        %{
          "type" => "tool_result",
          "tool_use_id" => "tu_123",
          "content" => "file1.ex\nfile2.ex",
          "is_error" => false
        }
      ]

      {:ok, msg} =
        %Message{}
        |> Message.changeset(%{role: "user", session_id: session.id, parts: parts})
        |> Repo.insert()

      found = Repo.get!(Message, msg.id)
      assert [%Synapsis.Part.ToolResult{tool_use_id: "tu_123", content: "file1.ex\nfile2.ex", is_error: false}] = found.parts
    end

    test "stores and retrieves reasoning part", %{session: session} do
      parts = [%{"type" => "reasoning", "content" => "Let me think about this..."}]

      {:ok, msg} =
        %Message{}
        |> Message.changeset(%{role: "assistant", session_id: session.id, parts: parts})
        |> Repo.insert()

      found = Repo.get!(Message, msg.id)
      assert [%Synapsis.Part.Reasoning{content: "Let me think about this..."}] = found.parts
    end

    test "stores and retrieves multiple mixed part types", %{session: session} do
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

      {:ok, msg} =
        %Message{}
        |> Message.changeset(%{role: "assistant", session_id: session.id, parts: parts})
        |> Repo.insert()

      found = Repo.get!(Message, msg.id)
      assert length(found.parts) == 3
      assert %Synapsis.Part.Text{content: "I'll help with that."} = Enum.at(found.parts, 0)
      assert %Synapsis.Part.ToolUse{tool: "file_read"} = Enum.at(found.parts, 1)
      assert %Synapsis.Part.Reasoning{content: "The file contains..."} = Enum.at(found.parts, 2)
    end

    test "stores and retrieves agent part", %{session: session} do
      parts = [%{"type" => "agent", "agent" => "plan", "message" => "Switching to plan mode."}]

      {:ok, msg} =
        %Message{}
        |> Message.changeset(%{role: "assistant", session_id: session.id, parts: parts})
        |> Repo.insert()

      found = Repo.get!(Message, msg.id)
      assert [%Synapsis.Part.Agent{agent: "plan", message: "Switching to plan mode."}] = found.parts
    end

    test "empty parts list persists correctly", %{session: session} do
      {:ok, msg} =
        %Message{}
        |> Message.changeset(%{role: "user", session_id: session.id, parts: []})
        |> Repo.insert()

      found = Repo.get!(Message, msg.id)
      assert found.parts == []
    end

    test "tool_result with is_error true round-trips", %{session: session} do
      parts = [
        %{
          "type" => "tool_result",
          "tool_use_id" => "tu_err",
          "content" => "Permission denied",
          "is_error" => true
        }
      ]

      {:ok, msg} =
        %Message{}
        |> Message.changeset(%{role: "user", session_id: session.id, parts: parts})
        |> Repo.insert()

      found = Repo.get!(Message, msg.id)
      assert [%Synapsis.Part.ToolResult{is_error: true, content: "Permission denied"}] = found.parts
    end
  end

  describe "persistence" do
    test "inserts and retrieves message", %{session: session} do
      {:ok, msg} =
        %Message{}
        |> Message.changeset(%{role: "user", session_id: session.id, token_count: 10})
        |> Repo.insert()

      found = Repo.get!(Message, msg.id)
      assert found.role == "user"
      assert found.token_count == 10
    end

    test "stores and retrieves parts", %{session: session} do
      parts = [%{"type" => "text", "content" => "Hello"}]

      {:ok, msg} =
        %Message{}
        |> Message.changeset(%{role: "user", session_id: session.id, parts: parts})
        |> Repo.insert()

      found = Repo.get!(Message, msg.id)
      assert length(found.parts) == 1
    end

    test "preloads session association", %{session: session} do
      {:ok, msg} =
        %Message{}
        |> Message.changeset(%{role: "assistant", session_id: session.id})
        |> Repo.insert()

      loaded = Repo.preload(msg, :session)
      assert loaded.session.id == session.id
    end
  end
end
