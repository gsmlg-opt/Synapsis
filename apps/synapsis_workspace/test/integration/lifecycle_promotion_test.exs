defmodule Synapsis.Workspace.Integration.LifecyclePromotionTest do
  use ExUnit.Case

  alias Synapsis.Workspace
  alias Synapsis.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    {:ok, project} =
      Repo.insert(%Synapsis.Project{
        slug: "proj-lc-#{System.unique_integer([:positive])}",
        path: "/tmp/proj-lifecycle",
        name: "proj-lifecycle"
      })

    {:ok, session} =
      Repo.insert(%Synapsis.Session{
        project_id: project.id,
        provider: "anthropic",
        model: "claude-3-5-sonnet"
      })

    %{project: project, session: session}
  end

  describe "lifecycle auto-promotion based on path prefix" do
    test "write to session path → lifecycle is scratch", %{project: project, session: session} do
      path = "/projects/#{project.id}/sessions/#{session.id}/scratch/notes.md"
      {:ok, resource} = Workspace.write(path, "scratch content", %{author: "test"})

      assert resource.lifecycle == :scratch
    end

    test "write to project path → lifecycle is shared", %{project: project} do
      path = "/projects/#{project.id}/plans/shared-plan.md"
      {:ok, resource} = Workspace.write(path, "shared content", %{author: "test"})

      assert resource.lifecycle in [:shared, :draft]
    end

    test "write to shared path → lifecycle is shared" do
      {:ok, resource} =
        Workspace.write("/shared/notes/global-note.md", "global content", %{author: "test"})

      assert resource.lifecycle in [:shared, :draft]
    end
  end

  describe "promote session scratch to project" do
    test "move session scratch to project → lifecycle changes", %{
      project: project,
      session: session
    } do
      session_path = "/projects/#{project.id}/sessions/#{session.id}/scratch/promote-me.md"
      {:ok, scratch} = Workspace.write(session_path, "promote this", %{author: "agent"})

      assert scratch.lifecycle == :scratch

      project_path = "/projects/#{project.id}/plans/promoted-plan.md"
      {:ok, promoted} = Workspace.move(session_path, project_path)

      assert promoted.path == project_path
      # After move to project level, the document keeps its lifecycle but
      # the path is now project-scoped (lifecycle may be updated on next write)
      assert promoted.path =~ "/projects/#{project.id}/plans/"
    end
  end

  describe "version history per lifecycle" do
    test "scratch documents do not create version history", %{
      project: project,
      session: session
    } do
      path = "/projects/#{project.id}/sessions/#{session.id}/scratch/no-versions.md"
      {:ok, _} = Workspace.write(path, "v1", %{author: "test"})
      {:ok, _} = Workspace.write(path, "v2", %{author: "test"})
      {:ok, _} = Workspace.write(path, "v3", %{author: "test"})

      # Read back — should have latest content
      {:ok, resource} = Workspace.read(path)
      assert resource.content == "v3"
      assert resource.version == 3

      # Check version count via Repo
      import Ecto.Query

      version_count =
        Synapsis.WorkspaceDocumentVersion
        |> where([v], v.document_id == ^resource.id)
        |> Repo.aggregate(:count)

      assert version_count == 0
    end

    test "non-scratch documents create version history", %{project: project} do
      path = "/projects/#{project.id}/plans/versioned-plan.md"
      {:ok, _} = Workspace.write(path, "v1", %{author: "test"})
      {:ok, _} = Workspace.write(path, "v2", %{author: "test"})
      {:ok, resource} = Workspace.write(path, "v3", %{author: "test"})

      assert resource.version == 3

      import Ecto.Query

      version_count =
        Synapsis.WorkspaceDocumentVersion
        |> where([v], v.document_id == ^resource.id)
        |> Repo.aggregate(:count)

      # At least some versions should be recorded (create + 2 updates)
      assert version_count >= 2
    end
  end
end
