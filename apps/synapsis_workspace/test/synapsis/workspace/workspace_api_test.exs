defmodule Synapsis.WorkspaceAPITest do
  use ExUnit.Case

  alias Synapsis.Workspace
  alias Synapsis.Workspace.Resource
  alias Synapsis.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    {:ok, project} =
      Repo.insert(%Synapsis.Project{
        slug: "api-test-project",
        path: "/tmp/api-test-project"
      })

    %{project: project}
  end

  # ---------------------------------------------------------------------------
  # validate_path/1
  # ---------------------------------------------------------------------------

  describe "validate_path/1" do
    test "accepts valid /shared/ path" do
      assert :ok = Workspace.validate_path("/shared/notes/test.md")
    end

    test "accepts valid /projects/ path", %{project: project} do
      assert :ok = Workspace.validate_path("/projects/#{project.id}/plans/auth.md")
    end

    test "accepts path without leading slash (normalized)" do
      assert :ok = Workspace.validate_path("shared/notes/test.md")
    end

    test "rejects path not starting with /shared/ or /projects/" do
      assert {:error, msg} = Workspace.validate_path("/other/stuff/file.md")
      assert msg =~ "must start with /shared/ or /projects/"
    end

    test "rejects path exceeding max length" do
      long_segment = String.duplicate("a", 200)

      long_path =
        "/shared/" <>
          Enum.map_join(1..6, "/", fn _ -> long_segment end) <>
          "/file.md"

      assert {:error, msg} = Workspace.validate_path(long_path)
      assert msg =~ "maximum length"
    end

    test "rejects path exceeding max depth" do
      # Build a path with 11 segments (max is 10)
      deep_path =
        "/shared/" <>
          Enum.map_join(1..10, "/", fn i -> "seg#{i}" end) <>
          "/file.md"

      assert {:error, msg} = Workspace.validate_path(deep_path)
      assert msg =~ "maximum depth"
    end

    test "rejects path containing . segment" do
      assert {:error, msg} = Workspace.validate_path("/shared/notes/./test.md")
      assert msg =~ ". or .."
    end

    test "rejects path containing .. segment" do
      assert {:error, msg} = Workspace.validate_path("/shared/notes/../test.md")
      assert msg =~ ". or .."
    end

    test "rejects path with invalid characters in segment" do
      assert {:error, msg} = Workspace.validate_path("/shared/notes/Test File!.md")
      assert msg =~ "lowercase alphanumeric"
    end

    test "rejects path with uppercase letters in segment" do
      assert {:error, msg} = Workspace.validate_path("/shared/Notes/test.md")
      assert msg =~ "lowercase alphanumeric"
    end

    test "accepts path with hyphens, underscores, and dots" do
      assert :ok = Workspace.validate_path("/shared/my-notes/my_file.test.md")
    end
  end

  # ---------------------------------------------------------------------------
  # move/2
  # ---------------------------------------------------------------------------

  describe "move/2" do
    test "moves a document to a new path" do
      {:ok, _} = Workspace.write("/shared/move/original.md", "content", %{author: "test"})

      assert {:ok, %Resource{} = resource} =
               Workspace.move("/shared/move/original.md", "/shared/move/renamed.md")

      assert resource.path == "/shared/move/renamed.md"
      assert resource.content == "content"
    end

    test "old path no longer exists after move" do
      {:ok, _} = Workspace.write("/shared/move/old-path.md", "data", %{author: "test"})
      {:ok, _} = Workspace.move("/shared/move/old-path.md", "/shared/move/new-path.md")

      assert {:error, :not_found} = Workspace.read("/shared/move/old-path.md")
    end

    test "new path is accessible after move" do
      {:ok, _} = Workspace.write("/shared/move/from.md", "hello", %{author: "test"})
      {:ok, _} = Workspace.move("/shared/move/from.md", "/shared/move/to.md")

      assert {:ok, resource} = Workspace.read("/shared/move/to.md")
      assert resource.content == "hello"
    end

    test "returns not_found when source path does not exist" do
      assert {:error, :not_found} =
               Workspace.move("/shared/move/nonexistent.md", "/shared/move/dest.md")
    end

    test "rejects move to an invalid target path" do
      {:ok, _} = Workspace.write("/shared/move/reject-src.md", "content", %{author: "test"})

      assert {:error, msg} =
               Workspace.move("/shared/move/reject-src.md", "/invalid/path/file.md")

      assert is_binary(msg)
    end

    test "rejects move to a domain-backed path" do
      {:ok, _} =
        Workspace.write("/shared/move/domain-src.md", "content", %{author: "test"})

      assert {:error, msg} =
               Workspace.move(
                 "/shared/move/domain-src.md",
                 "/shared/skills/my-skill.md"
               )

      assert msg =~ "domain-backed"
    end

    test "broadcasts :deleted for old path and :created for new path on move" do
      {:ok, _resource} =
        Workspace.write("/shared/move/broadcast-src.md", "content", %{author: "test"})

      Phoenix.PubSub.subscribe(Synapsis.PubSub, "workspace:global")

      {:ok, _} =
        Workspace.move("/shared/move/broadcast-src.md", "/shared/move/broadcast-dst.md")

      assert_receive {:workspace_changed, %{path: "/shared/move/broadcast-src.md", action: :deleted, resource_id: _}}
      assert_receive {:workspace_changed, %{path: "/shared/move/broadcast-dst.md", action: :created, resource_id: _}}
    end
  end

  # ---------------------------------------------------------------------------
  # stat/1
  # ---------------------------------------------------------------------------

  describe "stat/1" do
    test "returns metadata without content" do
      {:ok, written} =
        Workspace.write("/shared/stat/meta.md", "some content here", %{author: "test"})

      assert {:ok, resource} = Workspace.stat("/shared/stat/meta.md")

      assert resource.id == written.id
      assert resource.path == "/shared/stat/meta.md"
      assert resource.version == written.version
      assert is_nil(resource.content)
    end

    test "returns not_found for missing path" do
      assert {:error, :not_found} = Workspace.stat("/shared/stat/missing.md")
    end

    test "returns not_found for soft-deleted document" do
      {:ok, _} = Workspace.write("/shared/stat/will-delete.md", "content", %{author: "test"})
      :ok = Workspace.delete("/shared/stat/will-delete.md")

      assert {:error, :not_found} = Workspace.stat("/shared/stat/will-delete.md")
    end

    test "returns correct kind and visibility" do
      {:ok, _} = Workspace.write("/shared/stat/kind-check.md", "data", %{author: "test"})

      assert {:ok, resource} = Workspace.stat("/shared/stat/kind-check.md")

      assert resource.kind == :document
      assert resource.visibility == :global_shared
    end
  end

  # ---------------------------------------------------------------------------
  # exists?/1
  # ---------------------------------------------------------------------------

  describe "exists?/1" do
    test "returns true for an existing path" do
      {:ok, _} = Workspace.write("/shared/exists/present.md", "content", %{author: "test"})
      assert Workspace.exists?("/shared/exists/present.md") == true
    end

    test "returns false for a non-existent path" do
      assert Workspace.exists?("/shared/exists/absent.md") == false
    end

    test "returns false after a document is deleted" do
      {:ok, _} =
        Workspace.write("/shared/exists/deleted-check.md", "content", %{author: "test"})

      :ok = Workspace.delete("/shared/exists/deleted-check.md")

      assert Workspace.exists?("/shared/exists/deleted-check.md") == false
    end

    test "returns true for a document that was moved to a path" do
      {:ok, _} =
        Workspace.write("/shared/exists/pre-move.md", "content", %{author: "test"})

      {:ok, _} =
        Workspace.move("/shared/exists/pre-move.md", "/shared/exists/post-move.md")

      assert Workspace.exists?("/shared/exists/post-move.md") == true
      assert Workspace.exists?("/shared/exists/pre-move.md") == false
    end
  end

  # ---------------------------------------------------------------------------
  # write/3 — domain-backed path rejection
  # ---------------------------------------------------------------------------

  describe "write/3 domain path rejection" do
    test "rejects writes to /shared/skills/ paths" do
      assert {:error, msg} =
               Workspace.write("/shared/skills/my-skill.md", "content", %{author: "test"})

      assert msg =~ "domain-backed"
    end

    test "rejects writes to /shared/memory/ paths" do
      assert {:error, msg} =
               Workspace.write("/shared/memory/entry.md", "content", %{author: "test"})

      assert msg =~ "domain-backed"
    end

    test "rejects writes to project skills paths", %{project: project} do
      path = "/projects/#{project.id}/skills/my-skill.md"

      assert {:error, msg} = Workspace.write(path, "content", %{author: "test"})
      assert msg =~ "domain-backed"
    end

    test "rejects writes to project memory paths", %{project: project} do
      path = "/projects/#{project.id}/memory/entry.md"

      assert {:error, msg} = Workspace.write(path, "content", %{author: "test"})
      assert msg =~ "domain-backed"
    end

    test "rejects writes to session todo.md path", %{project: project} do
      {:ok, session} =
        Repo.insert(%Synapsis.Session{
          project_id: project.id,
          provider: "anthropic",
          model: "claude"
        })

      path = "/projects/#{project.id}/sessions/#{session.id}/todo.md"

      assert {:error, msg} = Workspace.write(path, "content", %{author: "test"})
      assert msg =~ "domain-backed"
    end

    test "allows writes to paths that look similar but are not domain-backed", %{project: project} do
      path = "/projects/#{project.id}/plans/skills-overview.md"

      assert {:ok, _resource} = Workspace.write(path, "content", %{author: "test"})
    end
  end

  # ---------------------------------------------------------------------------
  # PubSub broadcasts
  # ---------------------------------------------------------------------------

  describe "PubSub broadcasts on write" do
    test "broadcasts :created on first write to a global path" do
      Phoenix.PubSub.subscribe(Synapsis.PubSub, "workspace:global")

      {:ok, resource} =
        Workspace.write("/shared/pubsub/new-doc.md", "content", %{author: "test"})

      assert_receive {:workspace_changed,
                      %{path: "/shared/pubsub/new-doc.md", action: :created, resource_id: id}}

      assert id == resource.id
    end

    test "broadcasts :updated on subsequent writes to the same path" do
      {:ok, _} =
        Workspace.write("/shared/pubsub/update-doc.md", "v1", %{author: "test"})

      Phoenix.PubSub.subscribe(Synapsis.PubSub, "workspace:global")

      {:ok, resource} =
        Workspace.write("/shared/pubsub/update-doc.md", "v2", %{author: "test"})

      assert_receive {:workspace_changed,
                      %{path: "/shared/pubsub/update-doc.md", action: :updated, resource_id: id}}

      assert id == resource.id
    end

    test "broadcasts on project topic when writing to a project path", %{project: project} do
      path = "/projects/#{project.id}/plans/broadcast.md"

      Phoenix.PubSub.subscribe(Synapsis.PubSub, "workspace:#{project.id}")

      {:ok, resource} = Workspace.write(path, "content", %{author: "test"})

      assert_receive {:workspace_changed,
                      %{path: ^path, action: :created, resource_id: id}}

      assert id == resource.id
    end

    test "does not broadcast on workspace:global for project writes", %{project: project} do
      path = "/projects/#{project.id}/plans/no-global.md"

      Phoenix.PubSub.subscribe(Synapsis.PubSub, "workspace:global")

      {:ok, _} = Workspace.write(path, "content", %{author: "test"})

      refute_receive {:workspace_changed, %{path: ^path}}, 100
    end
  end

  describe "PubSub broadcasts on delete" do
    test "broadcasts :deleted on soft-delete by path" do
      {:ok, resource} =
        Workspace.write("/shared/pubsub/del-path.md", "content", %{author: "test"})

      Phoenix.PubSub.subscribe(Synapsis.PubSub, "workspace:global")

      :ok = Workspace.delete("/shared/pubsub/del-path.md")

      assert_receive {:workspace_changed,
                      %{path: "/shared/pubsub/del-path.md", action: :deleted, resource_id: id}}

      assert id == resource.id
    end

    test "broadcasts :deleted on soft-delete by ID" do
      {:ok, resource} =
        Workspace.write("/shared/pubsub/del-id.md", "content", %{author: "test"})

      Phoenix.PubSub.subscribe(Synapsis.PubSub, "workspace:global")

      :ok = Workspace.delete(resource.id)

      assert_receive {:workspace_changed,
                      %{path: "/shared/pubsub/del-id.md", action: :deleted, resource_id: id}}

      assert id == resource.id
    end

    test "broadcasts :deleted on project topic when deleting project doc", %{project: project} do
      path = "/projects/#{project.id}/plans/del-broadcast.md"
      {:ok, resource} = Workspace.write(path, "content", %{author: "test"})

      Phoenix.PubSub.subscribe(Synapsis.PubSub, "workspace:#{project.id}")

      :ok = Workspace.delete(path)

      assert_receive {:workspace_changed,
                      %{path: ^path, action: :deleted, resource_id: id}}

      assert id == resource.id
    end
  end
end
