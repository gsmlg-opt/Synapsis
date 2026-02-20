defmodule Synapsis.FailedAttemptTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.{FailedAttempt, Repo}

  setup do
    {:ok, project} =
      %Synapsis.Project{}
      |> Synapsis.Project.changeset(%{
        path: "/tmp/fa_test_#{System.unique_integer([:positive])}",
        slug: "fa-test-#{System.unique_integer([:positive])}"
      })
      |> Repo.insert()

    {:ok, session} =
      %Synapsis.Session{}
      |> Synapsis.Session.changeset(%{
        project_id: project.id,
        provider: "anthropic",
        model: "claude-sonnet-4-20250514"
      })
      |> Repo.insert()

    {:ok, session: session}
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

  describe "persistence" do
    test "inserts and reads back", %{session: session} do
      {:ok, fa} =
        %FailedAttempt{}
        |> FailedAttempt.changeset(%{
          session_id: session.id,
          attempt_number: 1,
          tool_call_hash: "hash123",
          error_message: "test fail",
          lesson: "don't do that"
        })
        |> Repo.insert()

      assert fa.id
      assert fa.attempt_number == 1
      assert fa.tool_call_hash == "hash123"
      assert fa.lesson == "don't do that"

      fetched = Repo.get(FailedAttempt, fa.id)
      assert fetched.session_id == session.id
    end

    test "cascades on session delete", %{session: session} do
      {:ok, fa} =
        %FailedAttempt{}
        |> FailedAttempt.changeset(%{session_id: session.id, attempt_number: 1})
        |> Repo.insert()

      Repo.delete(session)
      assert Repo.get(FailedAttempt, fa.id) == nil
    end
  end
end
