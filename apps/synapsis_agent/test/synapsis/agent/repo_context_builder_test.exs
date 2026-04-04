defmodule Synapsis.Agent.RepoContextBuilderTest do
  use Synapsis.Agent.DataCase

  alias Synapsis.Agent.RepoContextBuilder
  alias Synapsis.{Projects, Repos, Worktrees}

  defp unique_slug, do: "test-repo-#{System.unique_integer([:positive])}"

  describe "build/1" do
    test "returns {:ok, context} with correct structure" do
      slug = unique_slug()

      {:ok, project} =
        Projects.create(%{
          path: "/tmp/#{slug}",
          slug: slug,
          name: slug
        })

      {:ok, repo} =
        Repos.create(project.id, %{
          name: "my-repo",
          bare_path: "/tmp/repos/#{slug}.git",
          default_branch: "develop"
        })

      {:ok, worktree} =
        Worktrees.create(repo.id, %{
          branch: "feature/my-feature",
          base_branch: "develop",
          local_path: "/tmp/worktrees/#{slug}"
        })

      result = RepoContextBuilder.build(worktree.id)

      assert {:ok, context} = result

      assert %{
               repo: repo_info,
               worktree: worktree_info,
               git_status: git_status
             } = context

      assert repo_info.name == "my-repo"
      assert repo_info.default_branch == "develop"
      assert is_list(repo_info.remotes)

      assert worktree_info.branch == "feature/my-feature"
      assert worktree_info.base_branch == "develop"
      assert worktree_info.path == "/tmp/worktrees/#{slug}"

      # git_status is empty or error since no actual git dir exists
      assert is_map(git_status)
    end

    test "returns {:error, :not_found} for unknown worktree_id" do
      assert {:error, :not_found} = RepoContextBuilder.build(Ecto.UUID.generate())
    end

    test "includes remotes when present" do
      slug = unique_slug()

      {:ok, project} =
        Projects.create(%{
          path: "/tmp/#{slug}",
          slug: slug,
          name: slug
        })

      {:ok, repo} =
        Repos.create(project.id, %{
          name: "repo-with-remote",
          bare_path: "/tmp/repos/#{slug}.git",
          default_branch: "main"
        })

      {:ok, _remote} =
        Repos.add_remote(repo.id, %{
          name: "origin",
          url: "https://github.com/example/repo.git",
          is_primary: true
        })

      {:ok, worktree} =
        Worktrees.create(repo.id, %{
          branch: "main",
          local_path: "/tmp/worktrees/#{slug}"
        })

      {:ok, context} = RepoContextBuilder.build(worktree.id)

      assert length(context.repo.remotes) == 1
      [remote] = context.repo.remotes
      assert remote.name == "origin"
      assert remote.url == "https://github.com/example/repo.git"
      assert remote.is_primary == true
    end

    test "git_status is empty map with :files key when path does not exist" do
      slug = unique_slug()

      {:ok, project} =
        Projects.create(%{
          path: "/tmp/#{slug}",
          slug: slug,
          name: slug
        })

      {:ok, repo} =
        Repos.create(project.id, %{
          name: "no-disk-repo",
          bare_path: "/tmp/repos/nodisk-#{slug}.git",
          default_branch: "main"
        })

      {:ok, worktree} =
        Worktrees.create(repo.id, %{
          branch: "main",
          local_path: "/tmp/nonexistent/path/#{slug}"
        })

      {:ok, context} = RepoContextBuilder.build(worktree.id)

      assert Map.has_key?(context.git_status, :files)
    end
  end
end
