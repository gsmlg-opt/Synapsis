defmodule Synapsis.GitWorktreeTest do
  use ExUnit.Case, async: true

  alias Synapsis.GitWorktree

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # Initialize a git repo in the tmp dir
    {_, 0} = System.cmd("git", ["init", tmp_dir])
    {_, 0} = System.cmd("git", ["-C", tmp_dir, "config", "user.email", "test@test.com"])
    {_, 0} = System.cmd("git", ["-C", tmp_dir, "config", "user.name", "Test"])

    # Create an initial commit so we have a HEAD
    test_file = Path.join(tmp_dir, "README.md")
    File.write!(test_file, "# Test\n")
    {_, 0} = System.cmd("git", ["-C", tmp_dir, "add", "."])
    {_, 0} = System.cmd("git", ["-C", tmp_dir, "commit", "-m", "initial commit"])

    {:ok, project_path: tmp_dir}
  end

  describe "add/3" do
    test "creates a worktree on a new branch", %{project_path: project_path} do
      worktree_path = Path.join(project_path, ".trees/feature-1")

      assert {:ok, _} = GitWorktree.add(project_path, worktree_path, "feature-1")
      assert File.exists?(worktree_path)
      assert File.exists?(Path.join(worktree_path, "README.md"))
    end

    test "reuses existing branch if already exists", %{project_path: project_path} do
      # Create the branch first
      {_, 0} = System.cmd("git", ["-C", project_path, "branch", "existing-branch"])

      worktree_path = Path.join(project_path, ".trees/existing-branch")
      assert {:ok, _} = GitWorktree.add(project_path, worktree_path, "existing-branch")
      assert File.exists?(worktree_path)
    end

    test "returns error for invalid project path" do
      assert {:error, _} = GitWorktree.add("/nonexistent/path", "/tmp/wt", "branch")
    end
  end

  describe "remove/2" do
    test "removes an existing worktree", %{project_path: project_path} do
      worktree_path = Path.join(project_path, ".trees/to-remove")
      {:ok, _} = GitWorktree.add(project_path, worktree_path, "to-remove")
      assert File.exists?(worktree_path)

      assert {:ok, _} = GitWorktree.remove(project_path, worktree_path)
      refute File.exists?(worktree_path)
    end

    test "returns error for nonexistent worktree", %{project_path: project_path} do
      assert {:error, _} = GitWorktree.remove(project_path, "/nonexistent/worktree")
    end
  end

  describe "list/1" do
    test "lists the main worktree", %{project_path: project_path} do
      assert {:ok, worktrees} = GitWorktree.list(project_path)
      assert length(worktrees) >= 1

      main = Enum.find(worktrees, fn wt -> wt[:path] == project_path end)
      assert main != nil
      assert main[:head] != nil
    end

    test "includes added worktrees", %{project_path: project_path} do
      worktree_path = Path.join(project_path, ".trees/listed")
      {:ok, _} = GitWorktree.add(project_path, worktree_path, "listed")

      assert {:ok, worktrees} = GitWorktree.list(project_path)
      assert length(worktrees) >= 2

      added = Enum.find(worktrees, fn wt -> wt[:branch] == "listed" end)
      assert added != nil
      assert added[:path] == worktree_path
    end
  end

  describe "apply_patch/2" do
    test "applies a valid unified diff", %{project_path: project_path} do
      worktree_path = Path.join(project_path, ".trees/patch-test")
      {:ok, _} = GitWorktree.add(project_path, worktree_path, "patch-test")

      patch = """
      --- a/README.md
      +++ b/README.md
      @@ -1 +1,2 @@
       # Test
      +Added line
      """

      assert {:ok, _} = GitWorktree.apply_patch(worktree_path, patch)

      content = File.read!(Path.join(worktree_path, "README.md"))
      assert content =~ "Added line"
    end

    test "returns error for invalid patch", %{project_path: project_path} do
      worktree_path = Path.join(project_path, ".trees/bad-patch")
      {:ok, _} = GitWorktree.add(project_path, worktree_path, "bad-patch")

      assert {:error, _} = GitWorktree.apply_patch(worktree_path, "not a valid patch")
    end
  end

  describe "is_worktree?/1" do
    test "returns false for main working tree", %{project_path: project_path} do
      refute GitWorktree.is_worktree?(project_path)
    end

    test "returns true for an added worktree", %{project_path: project_path} do
      worktree_path = Path.join(project_path, ".trees/check-wt")
      {:ok, _} = GitWorktree.add(project_path, worktree_path, "check-wt")

      assert GitWorktree.is_worktree?(worktree_path)
    end

    test "returns false for non-git directory" do
      refute GitWorktree.is_worktree?("/tmp")
    end
  end
end
