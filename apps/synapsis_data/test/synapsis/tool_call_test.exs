defmodule Synapsis.ToolCallTest do
  use Synapsis.DataCase

  alias Synapsis.ToolCall

  describe "changeset/2" do
    test "valid changeset with required fields" do
      attrs = %{
        session_id: Ecto.UUID.generate(),
        tool_name: "file_read",
        input: %{"path" => "test.ex"}
      }

      changeset = ToolCall.changeset(%ToolCall{}, attrs)
      assert changeset.valid?
    end

    test "invalid without session_id" do
      attrs = %{tool_name: "file_read", input: %{}}
      changeset = ToolCall.changeset(%ToolCall{}, attrs)
      refute changeset.valid?
      assert %{session_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid without tool_name" do
      attrs = %{session_id: Ecto.UUID.generate(), input: %{}}
      changeset = ToolCall.changeset(%ToolCall{}, attrs)
      refute changeset.valid?
      assert %{tool_name: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid without input" do
      attrs = %{session_id: Ecto.UUID.generate(), tool_name: "file_read"}
      changeset = ToolCall.changeset(%ToolCall{}, attrs)
      refute changeset.valid?
      assert %{input: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates tool_name max length" do
      attrs = %{
        session_id: Ecto.UUID.generate(),
        tool_name: String.duplicate("a", 256),
        input: %{}
      }

      changeset = ToolCall.changeset(%ToolCall{}, attrs)
      refute changeset.valid?
      assert %{tool_name: [_]} = errors_on(changeset)
    end

    test "accepts optional fields" do
      attrs = %{
        session_id: Ecto.UUID.generate(),
        tool_name: "bash",
        input: %{"command" => "echo hi"},
        output: %{"result" => "hi"},
        status: :completed,
        duration_ms: 42,
        message_id: Ecto.UUID.generate()
      }

      changeset = ToolCall.changeset(%ToolCall{}, attrs)
      assert changeset.valid?
    end

    test "default status is pending" do
      attrs = %{
        session_id: Ecto.UUID.generate(),
        tool_name: "file_read",
        input: %{}
      }

      changeset = ToolCall.changeset(%ToolCall{}, attrs)
      assert Ecto.Changeset.get_field(changeset, :status) == :pending
    end
  end

  describe "complete_changeset/2" do
    test "sets completed status with output" do
      tool_call = %ToolCall{status: :pending}

      changeset =
        ToolCall.complete_changeset(tool_call, %{
          status: :completed,
          output: %{"result" => "ok"},
          duration_ms: 10
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :status) == :completed
    end

    test "sets error status with message" do
      tool_call = %ToolCall{status: :pending}

      changeset =
        ToolCall.complete_changeset(tool_call, %{
          status: :error,
          error_message: "timeout"
        })

      assert changeset.valid?
    end
  end

  describe "approve_changeset/1" do
    test "sets status to approved" do
      tool_call = %ToolCall{status: :pending}
      changeset = ToolCall.approve_changeset(tool_call)
      assert Ecto.Changeset.get_field(changeset, :status) == :approved
    end
  end

  describe "deny_changeset/1" do
    test "sets status to denied" do
      tool_call = %ToolCall{status: :pending}
      changeset = ToolCall.deny_changeset(tool_call)
      assert Ecto.Changeset.get_field(changeset, :status) == :denied
    end
  end
end
