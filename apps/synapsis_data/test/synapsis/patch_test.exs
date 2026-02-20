defmodule Synapsis.PatchTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.{Patch, FailedAttempt, Repo}

  setup do
    {:ok, project} =
      %Synapsis.Project{}
      |> Synapsis.Project.changeset(%{
        path: "/tmp/patch_test_#{System.unique_integer([:positive])}",
        slug: "patch-test-#{System.unique_integer([:positive])}"
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

  describe "changeset/2" do
    test "valid with required fields", %{session: session} do
      attrs = %{
        session_id: session.id,
        file_path: "lib/example.ex",
        diff_text: "--- a/lib/example.ex\n+++ b/lib/example.ex\n@@ -1 +1 @@\n-old\n+new"
      }

      changeset = Patch.changeset(%Patch{}, attrs)
      assert changeset.valid?
    end

    test "valid with all fields", %{session: session} do
      {:ok, fa} =
        %FailedAttempt{}
        |> FailedAttempt.changeset(%{session_id: session.id, attempt_number: 1})
        |> Repo.insert()

      attrs = %{
        session_id: session.id,
        failed_attempt_id: fa.id,
        file_path: "lib/example.ex",
        diff_text: "diff content",
        git_commit_hash: "abc123def",
        test_status: "passed",
        test_output: "All tests passed"
      }

      changeset = Patch.changeset(%Patch{}, attrs)
      assert changeset.valid?
    end

    test "invalid without required fields" do
      changeset = Patch.changeset(%Patch{}, %{})
      refute changeset.valid?
      assert %{session_id: ["can't be blank"]} = errors_on(changeset)
      assert %{file_path: ["can't be blank"]} = errors_on(changeset)
      assert %{diff_text: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid test_status", %{session: session} do
      attrs = %{
        session_id: session.id,
        file_path: "f.ex",
        diff_text: "diff",
        test_status: "invalid"
      }

      changeset = Patch.changeset(%Patch{}, attrs)
      refute changeset.valid?
      assert %{test_status: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "persistence" do
    test "inserts and reads back", %{session: session} do
      {:ok, patch} =
        %Patch{}
        |> Patch.changeset(%{
          session_id: session.id,
          file_path: "lib/app.ex",
          diff_text: "--- a/lib/app.ex\n+++ b/lib/app.ex",
          git_commit_hash: "deadbeef"
        })
        |> Repo.insert()

      assert patch.id
      assert patch.test_status == "pending"
      assert patch.git_commit_hash == "deadbeef"

      fetched = Repo.get(Patch, patch.id)
      assert fetched.file_path == "lib/app.ex"
    end

    test "cascades on session delete", %{session: session} do
      {:ok, patch} =
        %Patch{}
        |> Patch.changeset(%{
          session_id: session.id,
          file_path: "lib/app.ex",
          diff_text: "diff"
        })
        |> Repo.insert()

      Repo.delete(session)
      assert Repo.get(Patch, patch.id) == nil
    end

    test "nilifies failed_attempt_id on attempt delete", %{session: session} do
      {:ok, fa} =
        %FailedAttempt{}
        |> FailedAttempt.changeset(%{session_id: session.id, attempt_number: 1})
        |> Repo.insert()

      {:ok, patch} =
        %Patch{}
        |> Patch.changeset(%{
          session_id: session.id,
          failed_attempt_id: fa.id,
          file_path: "lib/app.ex",
          diff_text: "diff"
        })
        |> Repo.insert()

      Repo.delete(fa)
      fetched = Repo.get(Patch, patch.id)
      assert fetched.failed_attempt_id == nil
    end

    test "revert tracking", %{session: session} do
      {:ok, patch} =
        %Patch{}
        |> Patch.changeset(%{
          session_id: session.id,
          file_path: "lib/app.ex",
          diff_text: "diff"
        })
        |> Repo.insert()

      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      {:ok, reverted} =
        patch
        |> Patch.changeset(%{
          reverted_at: now,
          revert_reason: "Tests failed after applying patch"
        })
        |> Repo.update()

      assert reverted.reverted_at == now
      assert reverted.revert_reason == "Tests failed after applying patch"
    end
  end
end
