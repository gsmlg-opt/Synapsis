defmodule Synapsis.WorktreesTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.{Project, Repo, RepoRecord, RepoWorktree, Worktrees}

  defp insert_project do
    n = System.unique_integer([:positive])

    {:ok, project} =
      %Project{}
      |> Project.changeset(%{
        path: "/tmp/wt-test-#{n}",
        slug: "wt-test-#{n}",
        name: "wt-test-#{n}"
      })
      |> Repo.insert()

    project
  end

  defp insert_repo(project_id) do
    n = System.unique_integer([:positive])

    {:ok, repo} =
      %RepoRecord{}
      |> RepoRecord.changeset(%{
        project_id: project_id,
        name: "repo-#{n}",
        bare_path: "/repos/test-#{n}.git"
      })
      |> Repo.insert()

    repo
  end

  defp insert_worktree(repo_id, overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{branch: "feature-#{n}", local_path: "/tmp/wt-#{n}"},
        overrides
      )

    {:ok, wt} = Worktrees.create(repo_id, attrs)
    wt
  end

  describe "create/2" do
    test "creates a worktree for a repo" do
      project = insert_project()
      repo = insert_repo(project.id)
      n = System.unique_integer([:positive])

      assert {:ok, %RepoWorktree{} = wt} =
               Worktrees.create(repo.id, %{
                 branch: "feature-#{n}",
                 local_path: "/tmp/wt-#{n}"
               })

      assert wt.repo_id == repo.id
      assert wt.status == :active
    end

    test "rejects duplicate branch within the same repo" do
      project = insert_project()
      repo = insert_repo(project.id)
      n = System.unique_integer([:positive])

      {:ok, _} =
        Worktrees.create(repo.id, %{branch: "dup-branch-#{n}", local_path: "/tmp/wt-a-#{n}"})

      assert {:error, changeset} =
               Worktrees.create(repo.id, %{
                 branch: "dup-branch-#{n}",
                 local_path: "/tmp/wt-b-#{n}"
               })

      assert %{repo_id: _} = errors_on(changeset)
    end
  end

  describe "get/1" do
    test "returns worktree by id" do
      project = insert_project()
      repo = insert_repo(project.id)
      wt = insert_worktree(repo.id)

      found = Worktrees.get(wt.id)
      assert found.id == wt.id
    end

    test "returns nil for missing id" do
      assert Worktrees.get(Ecto.UUID.generate()) == nil
    end
  end

  describe "mark_completed/1" do
    test "transitions active worktree to completed" do
      project = insert_project()
      repo = insert_repo(project.id)
      wt = insert_worktree(repo.id)

      assert {:ok, updated} = Worktrees.mark_completed(wt)
      assert updated.status == :completed
      assert updated.completed_at != nil
    end

    test "rejects non-active worktree" do
      project = insert_project()
      repo = insert_repo(project.id)
      wt = insert_worktree(repo.id)
      {:ok, completed} = Worktrees.mark_completed(wt)

      assert {:error, changeset} = Worktrees.mark_completed(completed)
      assert %{status: _} = errors_on(changeset)
    end
  end

  describe "mark_failed/1" do
    test "transitions active worktree to failed" do
      project = insert_project()
      repo = insert_repo(project.id)
      wt = insert_worktree(repo.id)

      assert {:ok, updated} = Worktrees.mark_failed(wt)
      assert updated.status == :failed
      assert updated.completed_at != nil
    end

    test "rejects non-active worktree" do
      project = insert_project()
      repo = insert_repo(project.id)
      wt = insert_worktree(repo.id)
      {:ok, failed} = Worktrees.mark_failed(wt)

      assert {:error, changeset} = Worktrees.mark_failed(failed)
      assert %{status: _} = errors_on(changeset)
    end
  end

  describe "mark_cleaning/1" do
    test "transitions completed worktree to cleaning" do
      project = insert_project()
      repo = insert_repo(project.id)
      wt = insert_worktree(repo.id)
      {:ok, completed} = Worktrees.mark_completed(wt)

      assert {:ok, updated} = Worktrees.mark_cleaning(completed)
      assert updated.status == :cleaning
    end

    test "transitions failed worktree to cleaning" do
      project = insert_project()
      repo = insert_repo(project.id)
      wt = insert_worktree(repo.id)
      {:ok, failed} = Worktrees.mark_failed(wt)

      assert {:ok, updated} = Worktrees.mark_cleaning(failed)
      assert updated.status == :cleaning
    end

    test "rejects active worktree" do
      project = insert_project()
      repo = insert_repo(project.id)
      wt = insert_worktree(repo.id)

      assert {:error, changeset} = Worktrees.mark_cleaning(wt)
      assert %{status: _} = errors_on(changeset)
    end
  end

  describe "mark_cleaned/1" do
    test "transitions cleaning worktree and sets cleaned_at" do
      project = insert_project()
      repo = insert_repo(project.id)
      wt = insert_worktree(repo.id)
      {:ok, completed} = Worktrees.mark_completed(wt)
      {:ok, cleaning} = Worktrees.mark_cleaning(completed)

      assert {:ok, updated} = Worktrees.mark_cleaned(cleaning)
      assert updated.cleaned_at != nil
    end

    test "rejects non-cleaning worktree" do
      project = insert_project()
      repo = insert_repo(project.id)
      wt = insert_worktree(repo.id)

      assert {:error, changeset} = Worktrees.mark_cleaned(wt)
      assert %{status: _} = errors_on(changeset)
    end
  end

  describe "assign_agent/2" do
    test "sets the agent session id" do
      project = insert_project()
      repo = insert_repo(project.id)
      wt = insert_worktree(repo.id)
      session_id = Ecto.UUID.generate()

      assert {:ok, updated} = Worktrees.assign_agent(wt, session_id)
      assert updated.agent_session_id == session_id
    end

    test "allows reassignment to a different session id" do
      project = insert_project()
      repo = insert_repo(project.id)
      wt = insert_worktree(repo.id)
      first_id = Ecto.UUID.generate()
      second_id = Ecto.UUID.generate()

      {:ok, assigned} = Worktrees.assign_agent(wt, first_id)
      {:ok, reassigned} = Worktrees.assign_agent(assigned, second_id)

      assert reassigned.agent_session_id == second_id
    end
  end

  describe "list_active_for_repo/1" do
    test "returns only active worktrees for the given repo" do
      project = insert_project()
      repo = insert_repo(project.id)
      active_wt = insert_worktree(repo.id)
      completed_wt = insert_worktree(repo.id)
      {:ok, _} = Worktrees.mark_completed(completed_wt)

      ids = Worktrees.list_active_for_repo(repo.id) |> Enum.map(& &1.id)
      assert active_wt.id in ids
      refute completed_wt.id in ids
    end

    test "returns empty list for repo with no active worktrees" do
      project = insert_project()
      repo = insert_repo(project.id)
      assert Worktrees.list_active_for_repo(repo.id) == []
    end
  end

  describe "list_active_for_project/1" do
    test "returns active worktrees across all repos in the project" do
      project = insert_project()
      repo1 = insert_repo(project.id)
      repo2 = insert_repo(project.id)
      wt1 = insert_worktree(repo1.id)
      wt2 = insert_worktree(repo2.id)

      ids = Worktrees.list_active_for_project(project.id) |> Enum.map(& &1.id)
      assert wt1.id in ids
      assert wt2.id in ids
    end

    test "does not include worktrees from other projects" do
      project1 = insert_project()
      project2 = insert_project()
      repo1 = insert_repo(project1.id)
      repo2 = insert_repo(project2.id)
      wt1 = insert_worktree(repo1.id)
      wt2 = insert_worktree(repo2.id)

      ids1 = Worktrees.list_active_for_project(project1.id) |> Enum.map(& &1.id)
      assert wt1.id in ids1
      refute wt2.id in ids1
    end
  end

  describe "stale/1" do
    test "returns completed worktrees older than age_hours" do
      project = insert_project()
      repo = insert_repo(project.id)
      wt = insert_worktree(repo.id)
      {:ok, completed} = Worktrees.mark_completed(wt)

      # Set completed_at to 3 hours ago directly
      old_time = DateTime.add(DateTime.utc_now(), -3 * 3600, :second)

      completed
      |> RepoWorktree.changeset(%{completed_at: old_time})
      |> Repo.update!()

      results = Worktrees.stale(2)
      ids = Enum.map(results, & &1.id)
      assert completed.id in ids
    end

    test "does not return worktrees completed within age_hours" do
      project = insert_project()
      repo = insert_repo(project.id)
      wt = insert_worktree(repo.id)
      {:ok, completed} = Worktrees.mark_completed(wt)

      results = Worktrees.stale(24)
      ids = Enum.map(results, & &1.id)
      refute completed.id in ids
    end

    test "does not return active worktrees" do
      project = insert_project()
      repo = insert_repo(project.id)
      wt = insert_worktree(repo.id)

      results = Worktrees.stale(0)
      ids = Enum.map(results, & &1.id)
      refute wt.id in ids
    end

    test "returns failed worktrees older than threshold" do
      project = insert_project()
      repo = insert_repo(project.id)
      wt = insert_worktree(repo.id)
      {:ok, failed} = Worktrees.mark_failed(wt)

      old_time = DateTime.add(DateTime.utc_now(), -5 * 3600, :second)

      failed
      |> RepoWorktree.changeset(%{completed_at: old_time})
      |> Repo.update!()

      results = Worktrees.stale(2)
      ids = Enum.map(results, & &1.id)
      assert failed.id in ids
    end
  end
end
