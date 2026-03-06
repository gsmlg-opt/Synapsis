defmodule Synapsis.PromptBuilderTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.{PromptBuilder, FailedAttempt, MemoryEntry, Repo}

  setup do
    # Clear any pre-existing global memory entries to isolate tests
    import Ecto.Query
    Repo.delete_all(from(m in MemoryEntry, where: m.scope == "global"))

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

    {:ok, session: session, project: project}
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

    test "returns nil for a session_id with no matching records", %{session: _session} do
      bogus_id = Ecto.UUID.generate()
      assert PromptBuilder.build_failure_context(bogus_id) == nil
    end

    test "format includes bold attempt number marker", %{session: session} do
      insert_attempt(session.id, 5, "timeout", nil)

      result = PromptBuilder.build_failure_context(session.id)
      assert result =~ "**Attempt 5**"
    end

    test "lesson is prefixed with arrow marker", %{session: session} do
      insert_attempt(session.id, 1, "compile error", "Use correct module name")

      result = PromptBuilder.build_failure_context(session.id)

      # The format_entry joins: "- **Attempt 1**: compile error -> Lesson: Use correct module name"
      assert result =~ "Lesson: Use correct module name"
    end

    test "output ends with instruction to try different approach", %{session: session} do
      insert_attempt(session.id, 1, "error", "lesson")

      result = PromptBuilder.build_failure_context(session.id)
      assert String.ends_with?(String.trim(result), "fundamentally different approach.")
    end

    test "exactly 7 entries does not truncate", %{session: session} do
      for i <- 1..7 do
        insert_attempt(session.id, i, "Error #{i}", "Lesson #{i}")
      end

      result = PromptBuilder.build_failure_context(session.id)

      for i <- 1..7 do
        assert result =~ "Attempt #{i}"
      end
    end

    test "8 entries drops oldest and keeps most recent 7", %{session: session} do
      for i <- 1..8 do
        insert_attempt(session.id, i, "Error #{i}", "Lesson #{i}")
      end

      result = PromptBuilder.build_failure_context(session.id)
      # Attempt 1 should be dropped (oldest), 2-8 kept
      refute result =~ "Attempt 1**"
      assert result =~ "Attempt 2"
      assert result =~ "Attempt 8"
    end

    test "error_message with special characters renders correctly", %{session: session} do
      insert_attempt(
        session.id,
        1,
        "** (MatchError) no match of right-hand side value: {:error, :nxdomain}",
        nil
      )

      result = PromptBuilder.build_failure_context(session.id)
      assert result =~ "MatchError"
      assert result =~ "nxdomain"
    end

    test "entries from different sessions do not interfere" do
      # Create a second session
      {:ok, project2} =
        %Synapsis.Project{}
        |> Synapsis.Project.changeset(%{
          path: "/tmp/pb_test_other_#{System.unique_integer([:positive])}",
          slug: "pb-test-other-#{System.unique_integer([:positive])}"
        })
        |> Repo.insert()

      {:ok, session_a} =
        %Synapsis.Session{}
        |> Synapsis.Session.changeset(%{
          project_id: project2.id,
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })
        |> Repo.insert()

      {:ok, session_b} =
        %Synapsis.Session{}
        |> Synapsis.Session.changeset(%{
          project_id: project2.id,
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })
        |> Repo.insert()

      insert_attempt(session_a.id, 1, "Error from A", "Lesson A")
      insert_attempt(session_b.id, 1, "Error from B", "Lesson B")

      result_a = PromptBuilder.build_failure_context(session_a.id)
      result_b = PromptBuilder.build_failure_context(session_b.id)

      assert result_a =~ "Error from A"
      refute result_a =~ "Error from B"

      assert result_b =~ "Error from B"
      refute result_b =~ "Error from A"
    end
  end

  describe "build_memory_context/1" do
    test "returns nil when no memory entries", %{session: session} do
      assert PromptBuilder.build_memory_context(session.id) == nil
    end

    test "returns global memory content", %{session: session} do
      insert_memory("global", nil, "preference", "Always use snake_case")

      result = PromptBuilder.build_memory_context(session.id)
      assert result =~ "## Memory"
      assert result =~ "**preference**"
      assert result =~ "Always use snake_case"
    end

    test "returns project-scoped memory content", %{session: session, project: project} do
      insert_memory("project", project.id, "stack", "Elixir + Phoenix")

      result = PromptBuilder.build_memory_context(session.id)
      assert result =~ "## Memory"
      assert result =~ "**stack**"
      assert result =~ "Elixir + Phoenix"
    end

    test "combines global and project entries", %{session: session, project: project} do
      insert_memory("global", nil, "style", "Be concise")
      insert_memory("project", project.id, "framework", "Phoenix 1.8")

      result = PromptBuilder.build_memory_context(session.id)
      assert result =~ "Be concise"
      assert result =~ "Phoenix 1.8"
    end

    test "does not include entries from other projects", %{session: session} do
      {:ok, other_project} =
        %Synapsis.Project{}
        |> Synapsis.Project.changeset(%{
          path: "/tmp/other_#{System.unique_integer([:positive])}",
          slug: "other-#{System.unique_integer([:positive])}"
        })
        |> Repo.insert()

      insert_memory("project", other_project.id, "secret", "Should not appear")

      assert PromptBuilder.build_memory_context(session.id) == nil
    end

    test "returns nil for nonexistent session_id" do
      bogus_id = Ecto.UUID.generate()
      assert PromptBuilder.build_memory_context(bogus_id) == nil
    end
  end

  describe "build_prompt_context/1" do
    test "returns nil when neither memory nor failures exist", %{session: session} do
      assert PromptBuilder.build_prompt_context(session.id) == nil
    end

    test "returns only memory when no failures", %{session: session} do
      insert_memory("global", nil, "note", "Remember this")

      result = PromptBuilder.build_prompt_context(session.id)
      assert result =~ "## Memory"
      assert result =~ "Remember this"
      refute result =~ "Failed Approaches"
    end

    test "returns only failures when no memory", %{session: session} do
      insert_attempt(session.id, 1, "Compile error", "Fix imports")

      result = PromptBuilder.build_prompt_context(session.id)
      assert result =~ "## Failed Approaches"
      assert result =~ "Compile error"
      refute result =~ "## Memory"
    end

    test "combines both when both exist", %{session: session} do
      insert_memory("global", nil, "note", "Use pattern matching")
      insert_attempt(session.id, 1, "Timeout error", "Add timeout option")

      result = PromptBuilder.build_prompt_context(session.id)
      assert result =~ "## Memory"
      assert result =~ "Use pattern matching"
      assert result =~ "## Failed Approaches"
      assert result =~ "Timeout error"
    end
  end

  defp insert_memory(scope, scope_id, key, content) do
    {:ok, _} =
      %MemoryEntry{}
      |> MemoryEntry.changeset(%{
        scope: scope,
        scope_id: scope_id,
        key: key,
        content: content
      })
      |> Repo.insert()
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
