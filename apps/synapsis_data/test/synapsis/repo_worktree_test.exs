defmodule Synapsis.RepoWorktreeTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.{Project, Repo, RepoRecord, RepoWorktree}

  defp insert_project() do
    n = System.unique_integer([:positive])

    {:ok, project} =
      %Project{}
      |> Project.changeset(%{path: "/tmp/wt-test-#{n}", slug: "wt-test-#{n}", name: "wt-test-#{n}"})
      |> Repo.insert()

    project
  end

  defp insert_repo(project) do
    n = System.unique_integer([:positive])

    {:ok, repo} =
      %RepoRecord{}
      |> RepoRecord.changeset(%{
        project_id: project.id,
        name: "repo-#{n}",
        bare_path: "/repos/repo-#{n}.git"
      })
      |> Repo.insert()

    repo
  end

  describe "changeset/2" do
    test "valid with required fields" do
      project = insert_project()
      repo = insert_repo(project)

      cs =
        %RepoWorktree{}
        |> RepoWorktree.changeset(%{
          repo_id: repo.id,
          branch: "feature/my-feature",
          local_path: "/worktrees/my-feature"
        })

      assert cs.valid?
    end

    test "requires repo_id" do
      cs =
        %RepoWorktree{}
        |> RepoWorktree.changeset(%{branch: "feature/my-feature", local_path: "/worktrees/wt"})

      refute cs.valid?
      assert %{repo_id: ["can't be blank"]} = errors_on(cs)
    end

    test "requires branch" do
      project = insert_project()
      repo = insert_repo(project)

      cs =
        %RepoWorktree{}
        |> RepoWorktree.changeset(%{repo_id: repo.id, local_path: "/worktrees/wt"})

      refute cs.valid?
      assert %{branch: ["can't be blank"]} = errors_on(cs)
    end

    test "requires local_path" do
      project = insert_project()
      repo = insert_repo(project)

      cs =
        %RepoWorktree{}
        |> RepoWorktree.changeset(%{repo_id: repo.id, branch: "feature/my-feature"})

      refute cs.valid?
      assert %{local_path: ["can't be blank"]} = errors_on(cs)
    end

    test "defaults status to :active" do
      project = insert_project()
      repo = insert_repo(project)

      cs =
        %RepoWorktree{}
        |> RepoWorktree.changeset(%{
          repo_id: repo.id,
          branch: "feature/my-feature",
          local_path: "/worktrees/my-feature"
        })

      assert get_field(cs, :status) == :active
    end

    test "accepts :active status" do
      project = insert_project()
      repo = insert_repo(project)

      cs =
        %RepoWorktree{}
        |> RepoWorktree.changeset(%{
          repo_id: repo.id,
          branch: "feature/my-feature",
          local_path: "/worktrees/my-feature",
          status: :active
        })

      assert cs.valid?
    end

    test "accepts :completed status" do
      project = insert_project()
      repo = insert_repo(project)

      cs =
        %RepoWorktree{}
        |> RepoWorktree.changeset(%{
          repo_id: repo.id,
          branch: "feature/my-feature",
          local_path: "/worktrees/my-feature",
          status: :completed
        })

      assert cs.valid?
    end

    test "accepts :failed status" do
      project = insert_project()
      repo = insert_repo(project)

      cs =
        %RepoWorktree{}
        |> RepoWorktree.changeset(%{
          repo_id: repo.id,
          branch: "feature/my-feature",
          local_path: "/worktrees/my-feature",
          status: :failed
        })

      assert cs.valid?
    end

    test "accepts :cleaning status" do
      project = insert_project()
      repo = insert_repo(project)

      cs =
        %RepoWorktree{}
        |> RepoWorktree.changeset(%{
          repo_id: repo.id,
          branch: "feature/my-feature",
          local_path: "/worktrees/my-feature",
          status: :cleaning
        })

      assert cs.valid?
    end

    test "rejects invalid status" do
      project = insert_project()
      repo = insert_repo(project)

      cs =
        %RepoWorktree{}
        |> RepoWorktree.changeset(%{
          repo_id: repo.id,
          branch: "feature/my-feature",
          local_path: "/worktrees/my-feature",
          status: :invalid
        })

      refute cs.valid?
      assert %{status: _} = errors_on(cs)
    end

    test "enforces unique active branch within repo" do
      project = insert_project()
      repo = insert_repo(project)

      {:ok, _} =
        %RepoWorktree{}
        |> RepoWorktree.changeset(%{
          repo_id: repo.id,
          branch: "feature/active-branch",
          local_path: "/worktrees/wt-1",
          status: :active
        })
        |> Repo.insert()

      {:error, cs} =
        %RepoWorktree{}
        |> RepoWorktree.changeset(%{
          repo_id: repo.id,
          branch: "feature/active-branch",
          local_path: "/worktrees/wt-2",
          status: :active
        })
        |> Repo.insert()

      assert %{repo_id: ["has already been taken"]} = errors_on(cs)
    end

    test "allows same branch name in different repos" do
      project = insert_project()
      repo1 = insert_repo(project)
      repo2 = insert_repo(project)

      {:ok, _} =
        %RepoWorktree{}
        |> RepoWorktree.changeset(%{
          repo_id: repo1.id,
          branch: "feature/shared-branch",
          local_path: "/worktrees/wt-repo1"
        })
        |> Repo.insert()

      assert {:ok, _} =
               %RepoWorktree{}
               |> RepoWorktree.changeset(%{
                 repo_id: repo2.id,
                 branch: "feature/shared-branch",
                 local_path: "/worktrees/wt-repo2"
               })
               |> Repo.insert()
    end

    test "accepts optional fields" do
      project = insert_project()
      repo = insert_repo(project)

      cs =
        %RepoWorktree{}
        |> RepoWorktree.changeset(%{
          repo_id: repo.id,
          branch: "feature/my-feature",
          local_path: "/worktrees/my-feature",
          base_branch: "main",
          agent_session_id: "session-123",
          task_id: "task-456",
          metadata: %{"key" => "value"}
        })

      assert cs.valid?
    end
  end
end
