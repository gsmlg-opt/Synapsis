defmodule Synapsis.Session.WorkerTest do
  use Synapsis.DataCase, async: false

  alias Synapsis.Session.Worker
  alias Synapsis.Repo

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # Initialize a bare git repo for worktree support
    {_, 0} = System.cmd("git", ["init", tmp_dir])
    {_, 0} = System.cmd("git", ["-C", tmp_dir, "config", "user.email", "test@test.com"])
    {_, 0} = System.cmd("git", ["-C", tmp_dir, "config", "user.name", "Test"])
    File.write!(Path.join(tmp_dir, "README.md"), "# Test\n")
    {_, 0} = System.cmd("git", ["-C", tmp_dir, "add", "."])
    {_, 0} = System.cmd("git", ["-C", tmp_dir, "commit", "-m", "init"])

    {:ok, project} =
      %Synapsis.Project{}
      |> Synapsis.Project.changeset(%{
        path: tmp_dir,
        slug: "worker-test-#{System.unique_integer([:positive])}"
      })
      |> Repo.insert()

    {:ok, session} =
      %Synapsis.Session{}
      |> Synapsis.Session.changeset(%{
        project_id: project.id,
        provider: "anthropic",
        model: "claude-sonnet-4-20250514"
      })
      |> Repo.insert()

    {:ok, session: session, project_path: tmp_dir}
  end

  describe "init/1 — worktree setup" do
    test "sets worktree_path when project is a git repo", %{session: session, project_path: pp} do
      {:ok, pid} = start_supervised({Worker, session_id: session.id})

      state = :sys.get_state(pid)

      assert state.worktree_path != nil
      assert File.exists?(state.worktree_path)
      assert String.starts_with?(state.worktree_path, pp)
    end

    test "worktree_path is nil for non-git project" do
      non_git_dir = System.tmp_dir!() |> Path.join("no-git-#{System.unique_integer()}")
      File.mkdir_p!(non_git_dir)

      {:ok, project} =
        %Synapsis.Project{}
        |> Synapsis.Project.changeset(%{
          path: non_git_dir,
          slug: "no-git-#{System.unique_integer([:positive])}"
        })
        |> Repo.insert()

      {:ok, session} =
        %Synapsis.Session{}
        |> Synapsis.Session.changeset(%{
          project_id: project.id,
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })
        |> Repo.insert()

      {:ok, pid} = start_supervised({Worker, session_id: session.id})

      state = :sys.get_state(pid)

      assert state.worktree_path == nil

      File.rm_rf!(non_git_dir)
    end
  end
end
