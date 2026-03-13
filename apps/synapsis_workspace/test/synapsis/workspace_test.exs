defmodule Synapsis.WorkspaceTest do
  use ExUnit.Case

  alias Synapsis.Workspace
  alias Synapsis.Workspace.Resource

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Synapsis.Repo)
    # Create a test project
    {:ok, project} =
      Synapsis.Repo.insert(%Synapsis.Project{
        slug: "test-project",
        path: "/tmp/test-project"
      })

    %{project: project}
  end

  describe "write/3 and read/1" do
    test "creates a new document at a global path" do
      assert {:ok, %Resource{} = resource} =
               Workspace.write("/shared/notes/test.md", "# Test Note", %{author: "test-agent"})

      assert resource.path == "/shared/notes/test.md"
      assert resource.content == "# Test Note"
      assert resource.kind == :document
      assert resource.visibility == :global_shared
      assert resource.lifecycle == :shared
      assert resource.version == 1
    end

    test "creates a new document at a project path", %{project: project} do
      path = "/projects/#{project.id}/plans/auth.md"

      assert {:ok, %Resource{}} =
               Workspace.write(path, "# Auth Plan", %{author: "architect"})

      assert {:ok, resource} = Workspace.read(path)
      assert resource.content == "# Auth Plan"
      assert resource.visibility == :project_shared
    end

    test "updates an existing document" do
      path = "/shared/notes/update-test.md"
      {:ok, _} = Workspace.write(path, "v1 content", %{author: "agent"})
      {:ok, resource} = Workspace.write(path, "v2 content", %{author: "agent"})

      assert resource.content == "v2 content"
      assert resource.version == 2
    end

    test "reads by ID" do
      {:ok, resource} = Workspace.write("/shared/notes/id-test.md", "content", %{author: "test"})
      assert {:ok, read_resource} = Workspace.read(resource.id)
      assert read_resource.content == "content"
    end

    test "returns not_found for missing path" do
      assert {:error, :not_found} = Workspace.read("/shared/nonexistent.md")
    end
  end

  describe "list/2" do
    test "lists documents under a prefix" do
      Workspace.write("/shared/notes/a.md", "content a", %{author: "test"})
      Workspace.write("/shared/notes/b.md", "content b", %{author: "test"})
      Workspace.write("/shared/plans/c.md", "content c", %{author: "test"})

      {:ok, resources} = Workspace.list("/shared/notes")
      assert length(resources) == 2
      assert Enum.all?(resources, fn r -> String.starts_with?(r.path, "/shared/notes/") end)
    end

    test "lists with sort by recent" do
      Workspace.write("/shared/notes/old.md", "old", %{author: "test"})
      Process.sleep(10)
      Workspace.write("/shared/notes/new.md", "new", %{author: "test"})

      {:ok, resources} = Workspace.list("/shared/notes", sort: :recent)
      [first | _] = resources
      assert first.path == "/shared/notes/new.md"
    end

    test "returns empty list for non-existent prefix" do
      {:ok, resources} = Workspace.list("/shared/nonexistent")
      assert resources == []
    end
  end

  describe "search/2" do
    test "finds documents by content" do
      Workspace.write("/shared/notes/elixir.md", "Elixir is a functional language", %{
        author: "test"
      })

      Workspace.write("/shared/notes/python.md", "Python is an interpreted language", %{
        author: "test"
      })

      {:ok, results} = Workspace.search("elixir functional")
      assert length(results) >= 1
      assert Enum.any?(results, fn r -> r.path == "/shared/notes/elixir.md" end)
    end

    test "returns empty for no matches" do
      {:ok, results} = Workspace.search("xyznonexistent123")
      assert results == []
    end
  end

  describe "delete/1" do
    test "deletes a document by path" do
      {:ok, _} = Workspace.write("/shared/notes/del-by-path.md", "content", %{author: "test"})
      assert :ok = Workspace.delete("/shared/notes/del-by-path.md")
      assert {:error, :not_found} = Workspace.read("/shared/notes/del-by-path.md")
    end

    test "deletes a document by ID" do
      {:ok, resource} =
        Workspace.write("/shared/notes/del-by-id.md", "content", %{author: "test"})

      assert :ok = Workspace.delete(resource.id)
      assert {:error, :not_found} = Workspace.read(resource.id)
    end

    test "returns not_found for missing document" do
      assert {:error, :not_found} = Workspace.delete("/shared/notes/nonexistent.md")
    end

    test "deleted documents do not appear in list" do
      {:ok, _} = Workspace.write("/shared/notes/del-list.md", "content", %{author: "test"})
      :ok = Workspace.delete("/shared/notes/del-list.md")
      {:ok, resources} = Workspace.list("/shared/notes")
      refute Enum.any?(resources, fn r -> r.path == "/shared/notes/del-list.md" end)
    end
  end

  describe "version history" do
    test "creates version history for non-scratch documents" do
      path = "/shared/plans/versioned.md"
      {:ok, _} = Workspace.write(path, "v1", %{author: "test"})
      {:ok, _} = Workspace.write(path, "v2", %{author: "test"})
      {:ok, _} = Workspace.write(path, "v3", %{author: "test"})

      # Check versions exist
      import Ecto.Query

      versions =
        Synapsis.Repo.all(
          from v in Synapsis.WorkspaceDocumentVersion,
            order_by: [asc: v.version]
        )

      assert length(versions) >= 2
    end
  end
end
