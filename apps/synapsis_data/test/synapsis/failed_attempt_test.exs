defmodule Synapsis.FailedAttemptTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.FailedAttempt

  # ADR-006 C4: FailedAttempt is an embedded_schema validated by changeset only;
  # a session id is all these tests need.
  setup do
    {:ok, session: %{id: Ecto.UUID.generate()}}
  end

  describe "changeset/2" do
    test "valid with required fields", %{session: session} do
      attrs = %{session_id: session.id, attempt_number: 1}
      changeset = FailedAttempt.changeset(%FailedAttempt{}, attrs)
      assert changeset.valid?
    end

    test "valid with all fields", %{session: session} do
      attrs = %{
        session_id: session.id,
        attempt_number: 3,
        tool_call_hash: "abc123",
        tool_calls_snapshot: %{"calls" => [%{"tool" => "file_edit", "input" => %{}}]},
        error_message: "Compilation failed",
        lesson: "Do not modify the header guard",
        triggered_by: "test_regression",
        auditor_model: "claude-opus-4-20250514"
      }

      changeset = FailedAttempt.changeset(%FailedAttempt{}, attrs)
      assert changeset.valid?
    end

    test "invalid without session_id" do
      changeset = FailedAttempt.changeset(%FailedAttempt{}, %{attempt_number: 1})
      refute changeset.valid?
      assert %{session_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid without attempt_number", %{session: session} do
      changeset = FailedAttempt.changeset(%FailedAttempt{}, %{session_id: session.id})
      refute changeset.valid?
      assert %{attempt_number: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "apply_changes" do
    test "casts required and optional fields", %{session: session} do
      fa =
        %FailedAttempt{}
        |> FailedAttempt.changeset(%{
          session_id: session.id,
          attempt_number: 1,
          tool_call_hash: "hash123",
          error_message: "test fail",
          lesson: "don't do that"
        })
        |> Ecto.Changeset.apply_changes()

      assert fa.attempt_number == 1
      assert fa.tool_call_hash == "hash123"
      assert fa.lesson == "don't do that"
      assert fa.session_id == session.id
    end
  end
end
