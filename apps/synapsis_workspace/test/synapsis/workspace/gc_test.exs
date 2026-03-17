defmodule Synapsis.Workspace.GCTest do
  use ExUnit.Case

  alias Synapsis.Workspace.GC
  alias Synapsis.WorkspaceDocument
  alias Synapsis.WorkspaceDocumentVersion
  alias Synapsis.Repo

  import Ecto.Query

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    {:ok, project} =
      Repo.insert(%Synapsis.Project{
        slug: "gc-test-project",
        path: "/tmp/gc-test-project"
      })

    %{project: project}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp insert_doc(attrs) do
    defaults = %{
      path: "/shared/gc-test/#{System.unique_integer([:positive])}.md",
      kind: :document,
      visibility: :global_shared,
      lifecycle: :shared,
      content_format: :markdown,
      content_body: "test content",
      created_by: "test",
      updated_by: "test",
      version: 1
    }

    %WorkspaceDocument{}
    |> WorkspaceDocument.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp insert_version(doc, version_num) do
    %WorkspaceDocumentVersion{}
    |> WorkspaceDocumentVersion.changeset(%{
      document_id: doc.id,
      version: version_num,
      content_body: "content v#{version_num}",
      content_hash: :crypto.hash(:sha256, "v#{version_num}") |> Base.encode16(case: :lower),
      changed_by: "test"
    })
    |> Repo.insert!()
  end

  defp set_updated_at(schema, dt) do
    schema
    |> Ecto.Changeset.change(updated_at: dt)
    |> Repo.update!()
  end

  defp set_deleted_at(doc, dt) do
    doc
    |> Ecto.Changeset.change(deleted_at: dt)
    |> Repo.update!()
  end

  # ---------------------------------------------------------------------------
  # cleanup_session_scratch/0
  # ---------------------------------------------------------------------------

  describe "cleanup_session_scratch/0" do
    test "hard-deletes session_scratch docs with nil session_id past retention" do
      # A scratch doc with nil session_id that is stale (updated_at > 7 days ago)
      stale_time = DateTime.add(DateTime.utc_now(), -8, :day)

      doc =
        insert_doc(%{
          path: "/shared/gc-scratch/orphan.md",
          kind: :session_scratch,
          lifecycle: :scratch
        })

      set_updated_at(doc, stale_time)

      result = GC.cleanup_session_scratch()

      assert result >= 1

      assert is_nil(Repo.get(WorkspaceDocument, doc.id))
    end

    test "does not delete session_scratch docs with nil session_id within retention" do
      recent_time = DateTime.add(DateTime.utc_now(), -1, :day)

      doc =
        insert_doc(%{
          path: "/shared/gc-scratch/fresh-orphan.md",
          kind: :session_scratch,
          lifecycle: :scratch
        })

      set_updated_at(doc, recent_time)

      GC.cleanup_session_scratch()

      assert Repo.get(WorkspaceDocument, doc.id) != nil
    end

    test "also deletes versions associated with cleaned-up scratch docs" do
      stale_time = DateTime.add(DateTime.utc_now(), -10, :day)

      doc =
        insert_doc(%{
          path: "/shared/gc-scratch/orphan-with-versions.md",
          kind: :session_scratch,
          lifecycle: :scratch
        })

      # Insert a version (even though scratch skips versions normally, simulate leftover)
      _version = insert_version(doc, 1)

      set_updated_at(doc, stale_time)

      GC.cleanup_session_scratch()

      assert is_nil(Repo.get(WorkspaceDocument, doc.id))

      version_count =
        Repo.one(
          from v in WorkspaceDocumentVersion,
            where: v.document_id == ^doc.id,
            select: count(v.id)
        )

      assert version_count == 0
    end

    test "does not delete non-scratch docs regardless of age" do
      stale_time = DateTime.add(DateTime.utc_now(), -30, :day)

      doc =
        insert_doc(%{
          path: "/shared/gc-scratch/regular.md",
          kind: :document,
          lifecycle: :shared
        })

      set_updated_at(doc, stale_time)

      GC.cleanup_session_scratch()

      assert Repo.get(WorkspaceDocument, doc.id) != nil
    end

    test "cleans up scratch docs linked to a stale session", %{project: project} do
      {:ok, session} =
        Repo.insert(%Synapsis.Session{
          project_id: project.id,
          provider: "anthropic",
          model: "claude"
        })

      stale_time = DateTime.add(DateTime.utc_now(), -8, :day)
      set_updated_at(session, stale_time)

      doc =
        insert_doc(%{
          path: "/shared/gc-scratch/session-scratch.md",
          kind: :session_scratch,
          lifecycle: :scratch,
          session_id: session.id
        })

      result = GC.cleanup_session_scratch()

      assert result >= 1
      assert is_nil(Repo.get(WorkspaceDocument, doc.id))
    end

    test "does not delete scratch docs linked to a recent session", %{project: project} do
      {:ok, session} =
        Repo.insert(%Synapsis.Session{
          project_id: project.id,
          provider: "anthropic",
          model: "claude"
        })

      doc =
        insert_doc(%{
          path: "/shared/gc-scratch/active-session-scratch.md",
          kind: :session_scratch,
          lifecycle: :scratch,
          session_id: session.id
        })

      GC.cleanup_session_scratch()

      assert Repo.get(WorkspaceDocument, doc.id) != nil
    end
  end

  # ---------------------------------------------------------------------------
  # prune_draft_versions/0
  # ---------------------------------------------------------------------------

  describe "prune_draft_versions/0" do
    test "prunes versions beyond the retention limit for draft docs" do
      doc =
        insert_doc(%{
          path: "/shared/gc-draft/prune-me.md",
          kind: :document,
          lifecycle: :draft
        })

      # Insert 8 versions
      for i <- 1..8, do: insert_version(doc, i)

      result = GC.prune_draft_versions()

      assert result >= 3

      remaining =
        Repo.all(
          from v in WorkspaceDocumentVersion,
            where: v.document_id == ^doc.id,
            order_by: [desc: v.version]
        )

      # Default retention is 5; should keep at most 5
      assert length(remaining) <= 5
    end

    test "keeps the most recent versions when pruning" do
      doc =
        insert_doc(%{
          path: "/shared/gc-draft/keep-recent.md",
          kind: :document,
          lifecycle: :draft
        })

      for i <- 1..8, do: insert_version(doc, i)

      GC.prune_draft_versions()

      remaining_versions =
        Repo.all(
          from v in WorkspaceDocumentVersion,
            where: v.document_id == ^doc.id,
            order_by: [desc: v.version],
            select: v.version
        )

      # The highest version numbers should be kept
      assert Enum.max(remaining_versions) == 8
    end

    test "does not prune docs within retention count" do
      doc =
        insert_doc(%{
          path: "/shared/gc-draft/under-limit.md",
          kind: :document,
          lifecycle: :draft
        })

      # Only 3 versions — well within the default retention of 5
      for i <- 1..3, do: insert_version(doc, i)

      result = GC.prune_draft_versions()

      assert result == 0

      remaining =
        Repo.all(
          from v in WorkspaceDocumentVersion,
            where: v.document_id == ^doc.id
        )

      assert length(remaining) == 3
    end

    test "does not prune versions for non-draft lifecycle docs" do
      doc =
        insert_doc(%{
          path: "/shared/gc-draft/shared-lifecycle.md",
          kind: :document,
          lifecycle: :shared
        })

      for i <- 1..8, do: insert_version(doc, i)

      GC.prune_draft_versions()

      remaining =
        Repo.all(
          from v in WorkspaceDocumentVersion,
            where: v.document_id == ^doc.id
        )

      # GC only targets :draft lifecycle — should leave shared doc versions alone
      assert length(remaining) == 8
    end

    test "skips soft-deleted draft docs" do
      doc =
        insert_doc(%{
          path: "/shared/gc-draft/soft-deleted.md",
          kind: :document,
          lifecycle: :draft
        })

      for i <- 1..8, do: insert_version(doc, i)

      deleted_doc = set_deleted_at(doc, DateTime.utc_now())

      refute is_nil(deleted_doc.deleted_at)

      GC.prune_draft_versions()

      remaining =
        Repo.all(
          from v in WorkspaceDocumentVersion,
            where: v.document_id == ^doc.id
        )

      # GC skips deleted docs; all 8 versions remain
      assert length(remaining) == 8
    end

    test "returns 0 when there are no draft docs" do
      result = GC.prune_draft_versions()
      assert result == 0
    end
  end

  # ---------------------------------------------------------------------------
  # hard_delete_expired/0
  # ---------------------------------------------------------------------------

  describe "hard_delete_expired/0" do
    test "hard-deletes soft-deleted docs past retention" do
      doc =
        insert_doc(%{
          path: "/shared/gc-expired/expired.md"
        })

      expired_time = DateTime.add(DateTime.utc_now(), -31, :day)
      set_deleted_at(doc, expired_time)

      result = GC.hard_delete_expired()

      assert result >= 1
      assert is_nil(Repo.get(WorkspaceDocument, doc.id))
    end

    test "also hard-deletes versions of expired docs" do
      doc =
        insert_doc(%{
          path: "/shared/gc-expired/expired-with-versions.md"
        })

      for i <- 1..3, do: insert_version(doc, i)

      expired_time = DateTime.add(DateTime.utc_now(), -31, :day)
      set_deleted_at(doc, expired_time)

      GC.hard_delete_expired()

      assert is_nil(Repo.get(WorkspaceDocument, doc.id))

      version_count =
        Repo.one(
          from v in WorkspaceDocumentVersion,
            where: v.document_id == ^doc.id,
            select: count(v.id)
        )

      assert version_count == 0
    end

    test "does not delete soft-deleted docs still within retention window" do
      doc =
        insert_doc(%{
          path: "/shared/gc-expired/recent-deleted.md"
        })

      recent_delete_time = DateTime.add(DateTime.utc_now(), -5, :day)
      set_deleted_at(doc, recent_delete_time)

      GC.hard_delete_expired()

      # Still present in DB (not yet past retention)
      assert Repo.get(WorkspaceDocument, doc.id) != nil
    end

    test "does not delete active (non-deleted) docs" do
      doc =
        insert_doc(%{
          path: "/shared/gc-expired/active.md"
        })

      result = GC.hard_delete_expired()

      # Result should be 0 (no docs expired)
      assert result == 0
      assert Repo.get(WorkspaceDocument, doc.id) != nil
    end

    test "returns 0 when no expired docs exist" do
      result = GC.hard_delete_expired()
      assert result == 0
    end
  end

  # ---------------------------------------------------------------------------
  # cleanup_orphaned_blobs/0
  # ---------------------------------------------------------------------------

  describe "cleanup_orphaned_blobs/0" do
    test "returns 0 when blob root directory does not exist" do
      Application.put_env(:synapsis_workspace, :blob_store_root, "/tmp/synapsis-gc-test-nonexistent-#{System.unique_integer([:positive])}")

      result = GC.cleanup_orphaned_blobs()

      assert result == 0
    after
      Application.delete_env(:synapsis_workspace, :blob_store_root)
    end

    test "deletes blob files not referenced by any document" do
      tmp_root = Path.join(System.tmp_dir!(), "synapsis-gc-blob-test-#{System.unique_integer([:positive])}")
      Application.put_env(:synapsis_workspace, :blob_store_root, tmp_root)

      # Create an orphaned blob file in shard structure: <aa>/<bb>/<rest>
      ref = "aabbccddeeff0011223344556677889900112233445566778899aabbccddeeff00"
      <<aa::binary-size(2), bb::binary-size(2), rest::binary>> = ref
      blob_path = Path.join([tmp_root, aa, bb, rest])
      File.mkdir_p!(Path.dirname(blob_path))
      File.write!(blob_path, "orphaned content")

      # Backdate mtime so the blob passes the GC grace period filter
      old_time = {{2020, 1, 1}, {0, 0, 0}}
      File.touch!(blob_path, old_time)

      # No document references this blob
      result = GC.cleanup_orphaned_blobs()

      assert result == 1
      refute File.exists?(blob_path)
    after
      Application.delete_env(:synapsis_workspace, :blob_store_root)
    end

    test "does not delete blobs referenced by a document" do
      tmp_root = Path.join(System.tmp_dir!(), "synapsis-gc-blob-ref-test-#{System.unique_integer([:positive])}")
      Application.put_env(:synapsis_workspace, :blob_store_root, tmp_root)

      ref = "1122334455667788990011223344556677889900112233445566778899001122"
      <<aa::binary-size(2), bb::binary-size(2), rest::binary>> = ref
      blob_path = Path.join([tmp_root, aa, bb, rest])
      File.mkdir_p!(Path.dirname(blob_path))
      File.write!(blob_path, "referenced content")

      # Insert a document that references this blob
      _doc =
        insert_doc(%{
          path: "/shared/gc-blobs/with-blob.md",
          content_body: nil,
          blob_ref: ref
        })

      result = GC.cleanup_orphaned_blobs()

      # Blob should NOT be deleted
      assert result == 0
      assert File.exists?(blob_path)
    after
      Application.delete_env(:synapsis_workspace, :blob_store_root)
    end

    test "does not delete blobs referenced by a document version" do
      tmp_root = Path.join(System.tmp_dir!(), "synapsis-gc-blob-ver-test-#{System.unique_integer([:positive])}")
      Application.put_env(:synapsis_workspace, :blob_store_root, tmp_root)

      ref = "aabbccddeeff0011223344556677889900112233445566778899aabbccddeeff11"
      <<aa::binary-size(2), bb::binary-size(2), rest::binary>> = ref
      blob_path = Path.join([tmp_root, aa, bb, rest])
      File.mkdir_p!(Path.dirname(blob_path))
      File.write!(blob_path, "version blob content")

      doc = insert_doc(%{path: "/shared/gc-blobs/with-version-blob.md"})

      %WorkspaceDocumentVersion{}
      |> WorkspaceDocumentVersion.changeset(%{
        document_id: doc.id,
        version: 1,
        blob_ref: ref,
        content_hash: :crypto.hash(:sha256, "version content") |> Base.encode16(case: :lower),
        changed_by: "test"
      })
      |> Repo.insert!()

      result = GC.cleanup_orphaned_blobs()

      assert result == 0
      assert File.exists?(blob_path)
    after
      Application.delete_env(:synapsis_workspace, :blob_store_root)
    end
  end
end
