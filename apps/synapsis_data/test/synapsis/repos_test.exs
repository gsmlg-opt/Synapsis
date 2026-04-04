defmodule Synapsis.ReposTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.{Project, Repo, RepoRecord, RepoRemote, RepoWorktree, Repos}

  defp insert_project do
    n = System.unique_integer([:positive])

    {:ok, project} =
      %Project{}
      |> Project.changeset(%{
        path: "/tmp/repos-test-#{n}",
        slug: "repos-test-#{n}",
        name: "repos-test-#{n}"
      })
      |> Repo.insert()

    project
  end

  defp insert_repo(project_id, overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{bare_path: "/repos/test-#{n}.git", name: "repo-#{n}"},
        overrides
      )

    {:ok, repo} = Repos.create(project_id, attrs)
    repo
  end

  describe "create/2" do
    test "creates a repo for a project" do
      project = insert_project()

      assert {:ok, %RepoRecord{} = repo} =
               Repos.create(project.id, %{
                 name: "my-repo",
                 bare_path: "/repos/my-repo.git"
               })

      assert repo.project_id == project.id
      assert repo.name == "my-repo"
      assert repo.status == :active
    end

    test "rejects duplicate name within same project" do
      project = insert_project()
      insert_repo(project.id, %{name: "dup-name"})

      n = System.unique_integer([:positive])

      assert {:error, changeset} =
               Repos.create(project.id, %{
                 name: "dup-name",
                 bare_path: "/repos/other-#{n}.git"
               })

      assert %{project_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "allows same name in different projects" do
      project1 = insert_project()
      project2 = insert_project()
      n = System.unique_integer([:positive])

      assert {:ok, _} =
               Repos.create(project1.id, %{name: "shared-#{n}", bare_path: "/repos/a-#{n}.git"})

      assert {:ok, _} =
               Repos.create(project2.id, %{name: "shared-#{n}", bare_path: "/repos/b-#{n}.git"})
    end
  end

  describe "get/1" do
    test "returns repo by id" do
      project = insert_project()
      repo = insert_repo(project.id)
      found = Repos.get(repo.id)
      assert found.id == repo.id
    end

    test "returns nil for missing id" do
      assert Repos.get(Ecto.UUID.generate()) == nil
    end
  end

  describe "get_with_remotes/1" do
    test "returns nil for missing id" do
      assert Repos.get_with_remotes(Ecto.UUID.generate()) == nil
    end

    test "returns repo with remotes preloaded" do
      project = insert_project()
      repo = insert_repo(project.id)

      {:ok, _} =
        Repos.add_remote(repo.id, %{name: "origin", url: "https://github.com/example/repo.git"})

      found = Repos.get_with_remotes(repo.id)
      assert found.id == repo.id
      assert length(found.remotes) == 1
    end
  end

  describe "list_for_project/1" do
    test "returns active repos for a project" do
      project = insert_project()
      repo1 = insert_repo(project.id)
      repo2 = insert_repo(project.id)

      ids = Repos.list_for_project(project.id) |> Enum.map(& &1.id)
      assert repo1.id in ids
      assert repo2.id in ids
    end

    test "does not return archived repos" do
      project = insert_project()
      repo = insert_repo(project.id)
      {:ok, _} = Repos.archive(repo)

      ids = Repos.list_for_project(project.id) |> Enum.map(& &1.id)
      refute repo.id in ids
    end

    test "returns repos ordered by name" do
      project = insert_project()
      n = System.unique_integer([:positive])

      {:ok, repo_b} =
        Repos.create(project.id, %{name: "b-repo-#{n}", bare_path: "/repos/b-#{n}.git"})

      {:ok, repo_a} =
        Repos.create(project.id, %{name: "a-repo-#{n}", bare_path: "/repos/a-#{n}.git"})

      # Both should be present; a-repo should come before b-repo
      listed = Repos.list_for_project(project.id)
      ids = Enum.map(listed, & &1.id)
      assert repo_a.id in ids
      assert repo_b.id in ids

      a_pos = Enum.find_index(listed, &(&1.id == repo_a.id))
      b_pos = Enum.find_index(listed, &(&1.id == repo_b.id))
      assert a_pos < b_pos
    end
  end

  describe "add_remote/2" do
    test "adds a remote to a repo" do
      project = insert_project()
      repo = insert_repo(project.id)

      assert {:ok, %RepoRemote{} = remote} =
               Repos.add_remote(repo.id, %{name: "origin", url: "https://github.com/ex/r.git"})

      assert remote.repo_id == repo.id
      assert remote.name == "origin"
    end

    test "rejects duplicate remote name within same repo" do
      project = insert_project()
      repo = insert_repo(project.id)
      {:ok, _} = Repos.add_remote(repo.id, %{name: "origin", url: "https://github.com/a/b.git"})

      assert {:error, changeset} =
               Repos.add_remote(repo.id, %{name: "origin", url: "https://github.com/c/d.git"})

      assert %{repo_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "validates URL format" do
      project = insert_project()
      repo = insert_repo(project.id)

      assert {:error, changeset} =
               Repos.add_remote(repo.id, %{name: "bad", url: "not-a-url"})

      assert %{url: _} = errors_on(changeset)
    end

    test "accepts SSH URL format" do
      project = insert_project()
      repo = insert_repo(project.id)

      assert {:ok, _} =
               Repos.add_remote(repo.id, %{name: "ssh-remote", url: "git@github.com:ex/r.git"})
    end
  end

  describe "set_primary_remote/1" do
    test "sets the given remote as primary" do
      project = insert_project()
      repo = insert_repo(project.id)
      {:ok, remote} = Repos.add_remote(repo.id, %{name: "origin", url: "https://github.com/a/b.git"})

      assert {:ok, updated} = Repos.set_primary_remote(remote.id)
      assert updated.is_primary == true
    end

    test "clears previous primary when setting new primary" do
      project = insert_project()
      repo = insert_repo(project.id)
      {:ok, first} = Repos.add_remote(repo.id, %{name: "origin", url: "https://github.com/a/b.git"})
      {:ok, second} = Repos.add_remote(repo.id, %{name: "upstream", url: "https://github.com/c/d.git"})

      {:ok, _} = Repos.set_primary_remote(first.id)
      {:ok, _} = Repos.set_primary_remote(second.id)

      first_updated = Repo.get!(RepoRemote, first.id)
      second_updated = Repo.get!(RepoRemote, second.id)

      assert second_updated.is_primary == true
      refute first_updated.is_primary
    end

    test "returns error for missing remote id" do
      assert {:error, :not_found} = Repos.set_primary_remote(Ecto.UUID.generate())
    end
  end

  describe "archive/1" do
    test "archives a repo with no active worktrees" do
      project = insert_project()
      repo = insert_repo(project.id)
      assert {:ok, archived} = Repos.archive(repo)
      assert archived.status == :archived
    end

    test "fails if active worktrees exist" do
      project = insert_project()
      repo = insert_repo(project.id)
      n = System.unique_integer([:positive])

      %RepoWorktree{}
      |> RepoWorktree.changeset(%{
        repo_id: repo.id,
        branch: "feature-#{n}",
        local_path: "/tmp/wt-#{n}"
      })
      |> Repo.insert!()

      assert {:error, :active_worktrees_exist} = Repos.archive(repo)
    end
  end
end
