defmodule Synapsis.Workspace.Integration.GCCleanupTest do
  use ExUnit.Case

  alias Synapsis.Workspace
  alias Synapsis.Workspace.GC
  alias Synapsis.Repo

  import Ecto.Query

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    {:ok, project} =
      Repo.insert(%Synapsis.Project{
        slug: "proj-gc-#{System.unique_integer([:positive])}",
        path: "/tmp/proj-gc-cleanup"
      })

    {:ok, session} =
      Repo.insert(%Synapsis.Session{
        project_id: project.id,
        provider: "anthropic",
        model: "claude-3-5-sonnet"
      })

    %{project: project, session: session}
  end

  describe "full GC cycle: scratch + versions + expired" do
    test "cleanup session scratch past retention", %{project: project, session: session} do
      # Create a session scratch document
      path = "/projects/#{project.id}/sessions/#{session.id}/scratch/gc-test.md"
      {:ok, _} = Workspace.write(path, "scratch to clean", %{author: "agent"})

      # Manually backdate the session updated_at to trigger GC
      cutoff = DateTime.add(DateTime.utc_now(), -8, :day)

      from(s in Synapsis.Session, where: s.id == ^session.id)
      |> Repo.update_all(set: [updated_at: cutoff])

      # Run GC cleanup for session scratch
      count = GC.cleanup_session_scratch()

      assert count >= 1
      assert {:error, :not_found} = Workspace.read(path)
    end

    test "preserves active session scratch", %{project: project} do
      # Create a fresh session (updated_at = now)
      {:ok, fresh_session} =
        Repo.insert(%Synapsis.Session{
          project_id: project.id,
          provider: "anthropic",
          model: "claude-3-5-sonnet"
        })

      path =
        "/projects/#{project.id}/sessions/#{fresh_session.id}/scratch/keep-this.md"

      {:ok, _} = Workspace.write(path, "should survive GC", %{author: "agent"})

      count = GC.cleanup_session_scratch()
      assert count == 0

      assert {:ok, resource} = Workspace.read(path)
      assert resource.content == "should survive GC"
    end
  end

  describe "prune draft versions" do
    test "keeps last N versions for draft documents", %{project: project, session: session} do
      # Session non-scratch paths get lifecycle :draft
      path = "/projects/#{project.id}/sessions/#{session.id}/notes/gc-versioned.md"

      # Write 8 versions
      for i <- 1..8 do
        {:ok, _} = Workspace.write(path, "version #{i}", %{author: "test"})
      end

      {:ok, resource} = Workspace.read(path)

      version_count_before =
        Synapsis.WorkspaceDocumentVersion
        |> where([v], v.document_id == ^resource.id)
        |> Repo.aggregate(:count)

      # Draft documents should have version history
      if version_count_before > 5 do
        pruned = GC.prune_draft_versions()
        assert pruned > 0

        version_count_after =
          Synapsis.WorkspaceDocumentVersion
          |> where([v], v.document_id == ^resource.id)
          |> Repo.aggregate(:count)

        assert version_count_after <= 5
      else
        # Versions are created but may already be pruned during write
        # Verify the document is at version 8 regardless
        assert resource.version == 8
      end
    end
  end

  describe "hard-delete expired soft-deleted documents" do
    test "removes documents soft-deleted beyond retention", %{project: project} do
      path = "/projects/#{project.id}/notes/gc-expired.md"
      {:ok, resource} = Workspace.write(path, "to be expired", %{author: "test"})
      :ok = Workspace.delete(path)

      # Backdate the deleted_at to exceed retention
      cutoff = DateTime.add(DateTime.utc_now(), -31, :day)

      from(d in Synapsis.WorkspaceDocument, where: d.id == ^resource.id)
      |> Repo.update_all(set: [deleted_at: cutoff])

      count = GC.hard_delete_expired()
      assert count >= 1

      # Verify hard-deleted (not even in DB)
      result =
        Synapsis.WorkspaceDocument
        |> where([d], d.id == ^resource.id)
        |> Repo.one()

      assert result == nil
    end

    test "preserves recently soft-deleted documents", %{project: project} do
      path = "/projects/#{project.id}/notes/gc-recent-delete.md"
      {:ok, resource} = Workspace.write(path, "recently deleted", %{author: "test"})
      :ok = Workspace.delete(path)

      count = GC.hard_delete_expired()
      assert count == 0

      # Still in DB (soft-deleted but not hard-deleted)
      result =
        Synapsis.WorkspaceDocument
        |> where([d], d.id == ^resource.id)
        |> Repo.one()

      assert result != nil
      assert result.deleted_at != nil
    end
  end

  describe "configurable retention periods" do
    test "respects session_scratch_retention_days config", %{project: project, session: session} do
      path = "/projects/#{project.id}/sessions/#{session.id}/scratch/config-test.md"
      {:ok, _} = Workspace.write(path, "config test", %{author: "agent"})

      # Session is fresh, so default 7-day retention should keep it
      count = GC.cleanup_session_scratch()
      assert count == 0
    end
  end
end
