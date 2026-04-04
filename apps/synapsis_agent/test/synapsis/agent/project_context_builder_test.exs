defmodule Synapsis.Agent.ProjectContextBuilderTest do
  use Synapsis.Agent.DataCase

  alias Synapsis.Agent.ProjectContextBuilder
  alias Synapsis.Projects

  defp unique_slug, do: "test-project-#{System.unique_integer([:positive])}"

  describe "build/1" do
    test "returns correct structure with a created project" do
      slug = unique_slug()

      {:ok, project} =
        Projects.create(%{
          path: "/tmp/#{slug}",
          slug: slug,
          name: slug
        })

      context = ProjectContextBuilder.build(project.id)

      assert %{
               project: project_info,
               board_summary: board_summary,
               repos: repos,
               devlog_tail: devlog_tail
             } = context

      assert project_info.id == project.id
      assert project_info.name == project.name
      assert Map.has_key?(project_info, :description)

      assert %{
               total: total,
               by_column: by_column,
               in_progress: in_progress,
               blockers: blockers
             } = board_summary

      assert is_integer(total)
      assert is_map(by_column)
      assert is_list(in_progress)
      assert is_list(blockers)

      assert is_list(repos)
      assert is_list(devlog_tail)
    end

    test "handles missing board document gracefully" do
      slug = unique_slug()

      {:ok, project} =
        Projects.create(%{
          path: "/tmp/#{slug}",
          slug: slug,
          name: slug
        })

      context = ProjectContextBuilder.build(project.id)

      # No board document => empty summary
      assert context.board_summary.total == 0
      assert context.board_summary.by_column == %{}
      assert context.board_summary.in_progress == []
      assert context.board_summary.blockers == []
    end

    test "handles missing devlog gracefully" do
      slug = unique_slug()

      {:ok, project} =
        Projects.create(%{
          path: "/tmp/#{slug}",
          slug: slug,
          name: slug
        })

      context = ProjectContextBuilder.build(project.id)

      assert context.devlog_tail == []
    end

    test "returns empty repos list when project has no repos" do
      slug = unique_slug()

      {:ok, project} =
        Projects.create(%{
          path: "/tmp/#{slug}",
          slug: slug,
          name: slug
        })

      context = ProjectContextBuilder.build(project.id)

      assert context.repos == []
    end

    test "returns repo info with active worktree count" do
      slug = unique_slug()

      {:ok, project} =
        Projects.create(%{
          path: "/tmp/#{slug}",
          slug: slug,
          name: slug
        })

      {:ok, repo} =
        Synapsis.Repos.create(project.id, %{
          name: "my-repo",
          bare_path: "/tmp/repos/my-repo.git",
          default_branch: "main"
        })

      {:ok, _worktree} =
        Synapsis.Worktrees.create(repo.id, %{
          branch: "feature/test",
          local_path: "/tmp/worktrees/test"
        })

      context = ProjectContextBuilder.build(project.id)

      assert length(context.repos) == 1
      [repo_info] = context.repos
      assert repo_info.id == repo.id
      assert repo_info.name == "my-repo"
      assert repo_info.default_branch == "main"
      assert repo_info.active_worktrees == 1
    end
  end
end
