defmodule Synapsis.Workspace.ResourcesTest do
  use ExUnit.Case

  alias Synapsis.Workspace.Resources
  alias Synapsis.WorkspaceDocument
  alias Synapsis.WorkspaceDocumentVersion
  alias Synapsis.Repo

  import Ecto.Query

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    {:ok, project} =
      Repo.insert(%Synapsis.Project{
        slug: "res-test-project",
        path: "/tmp/res-test-project",
        name: "res-test-project"
      })

    %{project: project}
  end

  describe "create_document/3" do
    test "creates a document with resolved defaults" do
      assert {:ok, %WorkspaceDocument{} = doc} =
               Resources.create_document("/shared/notes/test.md", "hello", %{author: "agent-1"})

      assert doc.path == "/shared/notes/test.md"
      assert doc.content_body == "hello"
      assert doc.kind == :document
      assert doc.visibility == :global_shared
      assert doc.lifecycle == :shared
      assert doc.content_format == :markdown
      assert doc.created_by == "agent-1"
      assert doc.updated_by == "agent-1"
      assert doc.version == 1
    end

    test "creates a document at a project path", %{project: project} do
      path = "/projects/#{project.id}/plans/auth.md"

      assert {:ok, doc} =
               Resources.create_document(path, "# Plan", %{author: "architect"})

      assert doc.project_id == project.id
      assert doc.visibility == :project_shared
    end

    test "creates a session-scoped document", %{project: project} do
      {:ok, session} =
        Repo.insert(%Synapsis.Session{
          project_id: project.id,
          provider: "anthropic",
          model: "claude"
        })

      path = "/projects/#{project.id}/sessions/#{session.id}/scratch/notes.md"

      assert {:ok, doc} = Resources.create_document(path, "scratch", %{author: "agent"})
      assert doc.session_id == session.id
      assert doc.lifecycle == :scratch
      assert doc.visibility == :private
    end

    test "allows overriding kind and visibility" do
      assert {:ok, doc} =
               Resources.create_document("/shared/notes/custom.md", "content", %{
                 kind: :attachment,
                 visibility: :published,
                 author: "user"
               })

      assert doc.kind == :attachment
      assert doc.visibility == :published
    end

    test "rejects duplicate paths" do
      {:ok, _} = Resources.create_document("/shared/notes/dup.md", "v1", %{author: "a"})

      assert {:error, %Ecto.Changeset{}} =
               Resources.create_document("/shared/notes/dup.md", "v2", %{author: "b"})
    end
  end

  describe "get_by_path/1" do
    test "finds existing document" do
      {:ok, created} = Resources.create_document("/shared/notes/find.md", "content", %{})
      assert {:ok, found} = Resources.get_by_path("/shared/notes/find.md")
      assert found.id == created.id
    end

    test "normalizes path" do
      {:ok, _} = Resources.create_document("/shared/notes/norm.md", "content", %{})
      assert {:ok, _} = Resources.get_by_path("shared/notes/norm.md")
    end

    test "returns not_found for missing" do
      assert {:error, :not_found} = Resources.get_by_path("/shared/notes/missing.md")
    end

    test "returns not_found for soft-deleted" do
      {:ok, doc} = Resources.create_document("/shared/notes/deleted.md", "content", %{})
      {:ok, _} = Resources.soft_delete(doc)
      assert {:error, :not_found} = Resources.get_by_path("/shared/notes/deleted.md")
    end
  end

  describe "get_by_id/1" do
    test "finds existing document" do
      {:ok, created} = Resources.create_document("/shared/notes/byid.md", "content", %{})
      assert {:ok, found} = Resources.get_by_id(created.id)
      assert found.path == created.path
    end

    test "returns not_found for missing ID" do
      assert {:error, :not_found} = Resources.get_by_id(Ecto.UUID.generate())
    end

    test "returns not_found for soft-deleted by ID" do
      {:ok, doc} = Resources.create_document("/shared/notes/del-id.md", "content", %{})
      {:ok, _} = Resources.soft_delete(doc)
      assert {:error, :not_found} = Resources.get_by_id(doc.id)
    end
  end

  describe "upsert/3" do
    test "creates when path does not exist" do
      assert {:ok, doc} =
               Resources.upsert("/shared/notes/upsert-new.md", "content", %{author: "a"})

      assert doc.version == 1
    end

    test "updates when path exists" do
      {:ok, _} = Resources.upsert("/shared/notes/upsert-up.md", "v1", %{author: "a"})
      {:ok, doc} = Resources.upsert("/shared/notes/upsert-up.md", "v2", %{author: "b"})

      assert doc.content_body == "v2"
      assert doc.version == 2
      assert doc.updated_by == "b"
    end
  end

  describe "update_document/3" do
    test "increments version" do
      {:ok, doc} = Resources.create_document("/shared/notes/ver.md", "v1", %{author: "a"})
      {:ok, updated} = Resources.update_document(doc, "v2", %{author: "b"})

      assert updated.version == 2
      assert updated.content_body == "v2"
      assert updated.updated_by == "b"
    end

    test "allows updating metadata" do
      {:ok, doc} = Resources.create_document("/shared/notes/meta.md", "v1", %{author: "a"})

      {:ok, updated} =
        Resources.update_document(doc, "v2", %{
          author: "b",
          metadata: %{"title" => "My Note"}
        })

      assert updated.metadata == %{"title" => "My Note"}
    end
  end

  describe "soft_delete/1" do
    test "marks document as deleted" do
      {:ok, doc} = Resources.create_document("/shared/notes/softdel.md", "content", %{})
      {:ok, deleted} = Resources.soft_delete(doc)

      assert deleted.deleted_at != nil
    end

    test "soft-deleted document is excluded from get_by_path" do
      {:ok, doc} = Resources.create_document("/shared/notes/excl.md", "content", %{})
      {:ok, _} = Resources.soft_delete(doc)

      assert {:error, :not_found} = Resources.get_by_path("/shared/notes/excl.md")
    end

    test "soft-deleted document is excluded from list" do
      {:ok, doc} = Resources.create_document("/shared/notes/list-del.md", "content", %{})
      {:ok, _} = Resources.soft_delete(doc)

      docs = Resources.list("/shared/notes")
      refute Enum.any?(docs, fn d -> d.id == doc.id end)
    end
  end

  describe "list/2" do
    test "lists documents under prefix" do
      Resources.create_document("/shared/list/a.md", "a", %{})
      Resources.create_document("/shared/list/b.md", "b", %{})
      Resources.create_document("/shared/other/c.md", "c", %{})

      docs = Resources.list("/shared/list")
      assert length(docs) == 2
      assert Enum.all?(docs, fn d -> String.starts_with?(d.path, "/shared/list/") end)
    end

    test "filters by kind" do
      Resources.create_document("/shared/kind/doc.md", "d", %{kind: :document})
      Resources.create_document("/shared/kind/att.bin", "a", %{kind: :attachment})

      docs = Resources.list("/shared/kind", kind: :document)
      assert length(docs) == 1
      assert hd(docs).kind == :document
    end

    test "limits depth" do
      Resources.create_document("/shared/deep/a.md", "a", %{})
      Resources.create_document("/shared/deep/sub/b.md", "b", %{})
      Resources.create_document("/shared/deep/sub/sub2/c.md", "c", %{})

      docs = Resources.list("/shared/deep", depth: 1)
      assert length(docs) == 1
      assert hd(docs).path == "/shared/deep/a.md"
    end

    test "sorts by recent" do
      Resources.create_document("/shared/sort/old.md", "old", %{})
      Process.sleep(10)
      Resources.create_document("/shared/sort/new.md", "new", %{})

      docs = Resources.list("/shared/sort", sort: :recent)
      [first | _] = docs
      assert first.path == "/shared/sort/new.md"
    end

    test "respects limit" do
      for i <- 1..5 do
        Resources.create_document("/shared/lim/#{i}.md", "content #{i}", %{})
      end

      docs = Resources.list("/shared/lim", limit: 3)
      assert length(docs) == 3
    end

    test "returns empty for no matches" do
      docs = Resources.list("/shared/nope")
      assert docs == []
    end
  end

  describe "version history" do
    test "creates version records for shared lifecycle" do
      {:ok, doc} = Resources.create_document("/shared/vhist/shared.md", "v1", %{})
      {:ok, _} = Resources.update_document(doc, "v2", %{author: "a"})

      versions =
        Repo.all(
          from(v in WorkspaceDocumentVersion,
            where: v.document_id == ^doc.id,
            order_by: [asc: v.version]
          )
        )

      assert length(versions) == 1
      assert hd(versions).version == 1
      assert hd(versions).content_body == "v1"
    end

    test "skips version records for scratch lifecycle", %{project: project} do
      {:ok, session} =
        Repo.insert(%Synapsis.Session{
          project_id: project.id,
          provider: "anthropic",
          model: "claude"
        })

      path = "/projects/#{project.id}/sessions/#{session.id}/scratch/temp.md"
      {:ok, doc} = Resources.create_document(path, "v1", %{})
      {:ok, _} = Resources.update_document(doc, "v2", %{})

      versions =
        Repo.all(
          from(v in WorkspaceDocumentVersion,
            where: v.document_id == ^doc.id
          )
        )

      assert versions == []
    end

    test "prunes draft versions keeping last 5" do
      {:ok, doc} =
        Resources.create_document("/shared/vhist/draft.md", "v1", %{lifecycle: :draft})

      # Create 7 more updates (versions 2-8)
      Enum.reduce(2..8, doc, fn i, prev_doc ->
        {:ok, updated} = Resources.update_document(prev_doc, "v#{i}", %{})
        updated
      end)

      versions =
        Repo.all(
          from(v in WorkspaceDocumentVersion,
            where: v.document_id == ^doc.id,
            order_by: [desc: v.version]
          )
        )

      assert length(versions) <= 5
    end

    test "version includes content hash" do
      {:ok, doc} = Resources.create_document("/shared/vhist/hash.md", "content", %{})
      {:ok, _} = Resources.update_document(doc, "updated", %{})

      version =
        Repo.one(
          from(v in WorkspaceDocumentVersion,
            where: v.document_id == ^doc.id,
            limit: 1
          )
        )

      assert is_binary(version.content_hash)
      assert String.length(version.content_hash) == 64
    end
  end
end
