defmodule Synapsis.PromptBuilderTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.{PromptBuilder, FailedAttempt, Repo}

  setup do
    {:ok, project} =
      %Synapsis.Project{}
      |> Synapsis.Project.changeset(%{
        path: "/tmp/pb_test_#{System.unique_integer([:positive])}",
        slug: "pb-test-#{System.unique_integer([:positive])}"
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

  describe "build_failure_context/1" do
    test "returns nil when no failed attempts", %{session: session} do
      assert PromptBuilder.build_failure_context(session.id) == nil
    end

    test "returns formatted block with single attempt", %{session: session} do
      insert_attempt(session.id, 1, "Compilation failed", "Check imports first")

      result = PromptBuilder.build_failure_context(session.id)
      assert result =~ "## Failed Approaches"
      assert result =~ "Attempt 1"
      assert result =~ "Compilation failed"
      assert result =~ "Check imports first"
      assert result =~ "fundamentally different approach"
    end

    test "returns multiple entries in chronological order", %{session: session} do
      insert_attempt(session.id, 1, "Error A", "Lesson A")
      insert_attempt(session.id, 2, "Error B", "Lesson B")
      insert_attempt(session.id, 3, "Error C", "Lesson C")

      result = PromptBuilder.build_failure_context(session.id)
      assert result =~ "Attempt 1"
      assert result =~ "Attempt 2"
      assert result =~ "Attempt 3"

      # Verify chronological order
      pos_a = :binary.match(result, "Attempt 1") |> elem(0)
      pos_b = :binary.match(result, "Attempt 2") |> elem(0)
      pos_c = :binary.match(result, "Attempt 3") |> elem(0)
      assert pos_a < pos_b
      assert pos_b < pos_c
    end

    test "limits to 7 entries", %{session: session} do
      for i <- 1..10 do
        insert_attempt(session.id, i, "Error #{i}", "Lesson #{i}")
      end

      result = PromptBuilder.build_failure_context(session.id)
      # Should have entries 4-10 (most recent 7)
      refute result =~ "Attempt 1:"
      refute result =~ "Attempt 2:"
      refute result =~ "Attempt 3:"
      assert result =~ "Attempt 4"
      assert result =~ "Attempt 10"
    end

    test "handles entries without lesson", %{session: session} do
      insert_attempt(session.id, 1, "Error only", nil)

      result = PromptBuilder.build_failure_context(session.id)
      assert result =~ "Error only"
      refute result =~ "Lesson:"
    end

    test "handles entries with lesson but no error_message", %{session: session} do
      insert_attempt(session.id, 1, nil, "Always check imports first")

      result = PromptBuilder.build_failure_context(session.id)
      assert result =~ "Attempt 1"
      assert result =~ "Always check imports first"
      refute result =~ ": nil"
    end

    test "handles entries with neither error_message nor lesson", %{session: session} do
      insert_attempt(session.id, 1, nil, nil)

      result = PromptBuilder.build_failure_context(session.id)
      assert result =~ "Attempt 1"
      refute result =~ "nil"
    end
  end

  defp insert_attempt(session_id, number, error, lesson) do
    {:ok, _} =
      %FailedAttempt{}
      |> FailedAttempt.changeset(%{
        session_id: session_id,
        attempt_number: number,
        error_message: error,
        lesson: lesson
      })
      |> Repo.insert()
  end
end
