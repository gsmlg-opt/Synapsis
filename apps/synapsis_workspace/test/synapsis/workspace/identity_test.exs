defmodule Synapsis.Workspace.IdentityTest do
  use Synapsis.Workspace.TestCase

  alias Synapsis.Workspace.Identity

  describe "load_soul/1" do
    test "returns nil when no soul exists" do
      assert Identity.load_soul() == nil
    end

    test "returns global soul when no project" do
      Workspace.write("/shared/soul.md", "Be helpful.", %{author: "test"})
      assert Identity.load_soul() == "Be helpful."
    end

    test "returns project soul when project has one", %{project: project} do
      Workspace.write("/projects/#{project.id}/soul.md", "Project soul.", %{author: "test"})
      assert Identity.load_soul(project.id) =~ "Project soul."
    end

    test "concatenates global + project soul when both exist", %{project: project} do
      Workspace.write("/shared/soul.md", "Global soul.", %{author: "test"})
      Workspace.write("/projects/#{project.id}/soul.md", "Project override.", %{author: "test"})

      result = Identity.load_soul(project.id)
      assert result =~ "Global soul."
      assert result =~ "<!-- Project-specific -->"
      assert result =~ "Project override."
    end

    test "falls back to global soul when project has none", %{project: project} do
      Workspace.write("/shared/soul.md", "Global only.", %{author: "test"})
      assert Identity.load_soul(project.id) == "Global only."
    end

    test "does not error on missing file" do
      assert Identity.load_soul("nonexistent-project-id") == nil
    end
  end

  describe "load_identity/0" do
    test "returns identity content" do
      Workspace.write("/shared/identity.md", "I am a user.", %{author: "test"})
      assert Identity.load_identity() == "I am a user."
    end

    test "returns nil when not set" do
      assert Identity.load_identity() == nil
    end
  end

  describe "load_bootstrap/0" do
    test "returns bootstrap content" do
      Workspace.write("/shared/bootstrap.md", "Use git.", %{author: "test"})
      assert Identity.load_bootstrap() == "Use git."
    end

    test "returns nil when not set" do
      assert Identity.load_bootstrap() == nil
    end
  end

  describe "seed_defaults/0" do
    test "creates default soul.md" do
      Identity.seed_defaults()
      assert {:ok, resource} = Workspace.read("/shared/soul.md")
      assert resource.content =~ "You are a coding assistant"
    end

    test "creates default identity.md" do
      Identity.seed_defaults()
      assert {:ok, resource} = Workspace.read("/shared/identity.md")
      assert resource.content =~ "Edit this file"
    end

    test "creates default bootstrap.md" do
      Identity.seed_defaults()
      assert {:ok, resource} = Workspace.read("/shared/bootstrap.md")
      assert resource.content =~ "development environment"
    end

    test "does not overwrite existing files" do
      Workspace.write("/shared/soul.md", "Custom soul.", %{author: "test"})
      Identity.seed_defaults()
      assert {:ok, resource} = Workspace.read("/shared/soul.md")
      assert resource.content == "Custom soul."
    end

    test "is idempotent" do
      Identity.seed_defaults()
      Identity.seed_defaults()
      assert {:ok, _} = Workspace.read("/shared/soul.md")
    end
  end

  describe "load_all/1" do
    test "loads all identity files", %{project: project} do
      Workspace.write("/shared/soul.md", "Soul.", %{author: "test"})
      Workspace.write("/shared/identity.md", "Identity.", %{author: "test"})
      Workspace.write("/shared/bootstrap.md", "Bootstrap.", %{author: "test"})
      Workspace.write("/projects/#{project.id}/context.md", "Context.", %{author: "test"})

      result = Identity.load_all(project.id)
      assert result.soul =~ "Soul."
      assert result.identity == "Identity."
      assert result.bootstrap == "Bootstrap."
      assert result.project_context == "Context."
    end

    test "returns nil for missing files" do
      result = Identity.load_all()
      assert result.soul == nil
      assert result.identity == nil
      assert result.bootstrap == nil
    end
  end
end
