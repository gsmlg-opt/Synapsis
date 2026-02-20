defmodule Synapsis.Session.WorkspaceManagerTest do
  use Synapsis.DataCase, async: false

  alias Synapsis.Session.WorkspaceManager
  alias Synapsis.Repo

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # Initialize a git repo in the tmp dir
    {_, 0} = System.cmd("git", ["init", tmp_dir])
    {_, 0} = System.cmd("git", ["-C", tmp_dir, "config", "user.email", "test@test.com"])
    {_, 0} = System.cmd("git", ["-C", tmp_dir, "config", "user.name", "Test"])

    # Create initial file and commit
    File.write!(Path.join(tmp_dir, "hello.txt"), "Hello\n")
    {_, 0} = System.cmd("git", ["-C", tmp_dir, "add", "."])
    {_, 0} = System.cmd("git", ["-C", tmp_dir, "commit", "-m", "initial"])

    # Create a DB project + session for foreign keys
    {:ok, project} =
      %Synapsis.Project{}
      |> Synapsis.Project.changeset(%{
        path: tmp_dir,
        slug: "wm-test-#{System.unique_integer([:positive])}"
      })
      |> Repo.insert()

    {:ok, session} =
      %Synapsis.Session{}
      |> Synapsis.Session.changeset(%{
        project_id: project.id,
        provider: "anthropic",
        model: "test-model"
      })
      |> Repo.insert()

    {:ok, project_path: tmp_dir, session: session}
  end

  describe "setup/2 and teardown/2" do
    test "creates and removes a worktree", %{project_path: pp, session: session} do
      assert {:ok, wt_path} = WorkspaceManager.setup(pp, session.id)
      assert File.exists?(wt_path)
      assert File.exists?(Path.join(wt_path, "hello.txt"))

      assert :ok = WorkspaceManager.teardown(pp, session.id)
      refute File.exists?(wt_path)
    end
  end

  describe "apply_and_test/4" do
    test "applies patch and records passing test", %{project_path: pp, session: session} do
      {:ok, _wt_path} = WorkspaceManager.setup(pp, session.id)

      diff = """
      --- a/hello.txt
      +++ b/hello.txt
      @@ -1 +1,2 @@
       Hello
      +World
      """

      # Use a simple command that always passes
      assert {:ok, patch} = WorkspaceManager.apply_and_test(pp, session.id, diff, "true")
      assert patch.test_status == "passed"
      assert patch.file_path == "hello.txt"
      assert patch.session_id == session.id

      WorkspaceManager.teardown(pp, session.id)
    end

    test "records failing test", %{project_path: pp, session: session} do
      {:ok, _wt_path} = WorkspaceManager.setup(pp, session.id)

      diff = """
      --- a/hello.txt
      +++ b/hello.txt
      @@ -1 +1,2 @@
       Hello
      +World
      """

      # Use a command that always fails
      assert {:ok, patch} = WorkspaceManager.apply_and_test(pp, session.id, diff, "false")
      assert patch.test_status == "failed"

      WorkspaceManager.teardown(pp, session.id)
    end

    test "returns error for bad patch", %{project_path: pp, session: session} do
      {:ok, _wt_path} = WorkspaceManager.setup(pp, session.id)

      assert {:error, reason} = WorkspaceManager.apply_and_test(pp, session.id, "bad patch", "true")
      assert reason =~ "Patch apply failed"

      WorkspaceManager.teardown(pp, session.id)
    end
  end

  describe "revert_and_learn/3" do
    test "reverts patch and records reason", %{project_path: pp, session: session} do
      {:ok, _wt_path} = WorkspaceManager.setup(pp, session.id)

      diff = """
      --- a/hello.txt
      +++ b/hello.txt
      @@ -1 +1,2 @@
       Hello
      +World
      """

      {:ok, patch} = WorkspaceManager.apply_and_test(pp, session.id, diff, "true")
      assert {:ok, reverted} = WorkspaceManager.revert_and_learn(patch.id, "Broke the build", pp)
      assert reverted.reverted_at != nil
      assert reverted.revert_reason == "Broke the build"

      WorkspaceManager.teardown(pp, session.id)
    end
  end

  describe "list_patches/2" do
    test "lists patches by session", %{project_path: pp, session: session} do
      {:ok, _} = WorkspaceManager.setup(pp, session.id)

      diff = """
      --- a/hello.txt
      +++ b/hello.txt
      @@ -1 +1,2 @@
       Hello
      +World
      """

      {:ok, _} = WorkspaceManager.apply_and_test(pp, session.id, diff, "true")
      patches = WorkspaceManager.list_patches(session.id)
      assert length(patches) == 1

      passed = WorkspaceManager.list_patches(session.id, status: "passed")
      assert length(passed) == 1

      failed = WorkspaceManager.list_patches(session.id, status: "failed")
      assert length(failed) == 0

      WorkspaceManager.teardown(pp, session.id)
    end
  end
end
