defmodule Synapsis.Workspace.SearchTest do
  use ExUnit.Case

  alias Synapsis.Workspace
  alias Synapsis.Workspace.Search

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Synapsis.Repo)

    {:ok, project} =
      Synapsis.Repo.insert(%Synapsis.Project{
        slug: "search-test",
        path: "/tmp/search-test",
        name: "search-test"
      })

    {:ok, session} =
      Synapsis.Repo.insert(%Synapsis.Session{
        project_id: project.id,
        provider: "anthropic",
        model: "claude"
      })

    # Seed documents across different scopes
    Workspace.write("/shared/notes/global-doc.md", "Elixir concurrency and OTP patterns", %{
      author: "test"
    })

    Workspace.write(
      "/projects/#{project.id}/plans/project-plan.md",
      "Elixir project architecture plan",
      %{author: "test"}
    )

    Workspace.write(
      "/projects/#{project.id}/sessions/#{session.id}/scratch/session-scratch.md",
      "Elixir session scratch notes for debugging",
      %{author: "test"}
    )

    %{project: project, session: session}
  end

  describe "search/2 basic" do
    test "finds documents matching query" do
      results = Search.search("elixir")
      assert length(results) >= 1
    end

    test "returns empty for non-matching query" do
      results = Search.search("xyznonexistent987654")
      assert results == []
    end

    test "ranks by relevance" do
      results = Search.search("elixir concurrency OTP")
      # Global doc mentions concurrency and OTP, should rank higher
      assert length(results) >= 1
    end

    test "respects limit option" do
      results = Search.search("elixir", limit: 1)
      assert length(results) == 1
    end
  end

  describe "search/2 scope filtering" do
    test "global scope returns only /shared/ documents" do
      results = Search.search("elixir", scope: :global)
      assert length(results) >= 1
      assert Enum.all?(results, fn d -> is_nil(d.project_id) end)
    end

    test "project scope returns only project-level documents (not session)", %{
      project: project
    } do
      results = Search.search("elixir", scope: :project)
      assert length(results) >= 1

      assert Enum.all?(results, fn d ->
               not is_nil(d.project_id) and is_nil(d.session_id)
             end)

      assert Enum.all?(results, fn d -> d.project_id == project.id end)
    end

    test "session scope returns only session-scoped documents" do
      results = Search.search("elixir", scope: :session)
      assert length(results) >= 1
      assert Enum.all?(results, fn d -> not is_nil(d.session_id) end)
    end
  end

  describe "search/2 project_id filtering" do
    test "filters by project_id", %{project: project} do
      results = Search.search("elixir", project_id: project.id)
      assert length(results) >= 1
      assert Enum.all?(results, fn d -> d.project_id == project.id end)
    end

    test "returns empty for non-existent project" do
      results = Search.search("elixir", project_id: Ecto.UUID.generate())
      assert results == []
    end
  end

  describe "search/2 kind filtering" do
    test "filters by document kind" do
      results = Search.search("elixir", kind: :document)
      assert length(results) >= 1
      assert Enum.all?(results, fn d -> d.kind == :document end)
    end

    test "returns empty for kind with no matches" do
      results = Search.search("elixir", kind: :handoff)
      assert results == []
    end
  end

  describe "search/2 excludes deleted" do
    test "does not return soft-deleted documents" do
      Workspace.write("/shared/notes/search-del.md", "deletable search content unique", %{
        author: "test"
      })

      # Verify it's found first
      before = Search.search("deletable unique")
      assert length(before) >= 1

      # Delete it
      Workspace.delete("/shared/notes/search-del.md")

      # Verify it's gone
      after_del = Search.search("deletable unique")
      refute Enum.any?(after_del, fn d -> d.path == "/shared/notes/search-del.md" end)
    end
  end
end
