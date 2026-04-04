defmodule Synapsis.Git.WorktreeTest do
  use ExUnit.Case, async: true

  alias Synapsis.Git.{Branch, Worktree}

  defp setup_bare_repo(base) do
    src = Path.join(base, "src")
    File.mkdir_p!(src)
    System.cmd("git", ["init"], cd: src)
    System.cmd("git", ["config", "user.email", "test@test.com"], cd: src)
    System.cmd("git", ["config", "user.name", "Test"], cd: src)
    File.write!(Path.join(src, "README.md"), "# Test")
    System.cmd("git", ["add", "."], cd: src)
    System.cmd("git", ["commit", "-m", "initial"], cd: src)

    bare = Path.join(base, "bare.git")
    System.cmd("git", ["clone", "--bare", src, bare])

    # Create a branch we can check out in a worktree
    :ok = Branch.create(bare, "work-branch", "HEAD")

    bare
  end

  setup do
    base =
      Path.join(System.tmp_dir!(), "worktree_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    bare = setup_bare_repo(base)
    {:ok, base: base, bare: bare}
  end

  describe "create/3" do
    test "creates worktree directory with checked-out files", %{base: base, bare: bare} do
      wt_path = Path.join(base, "worktrees/wt1")
      assert :ok = Worktree.create(bare, wt_path, "work-branch")
      assert File.dir?(wt_path)
      # The README from the initial commit should be present
      assert File.exists?(Path.join(wt_path, "README.md"))
    end

    test "creates parent directories automatically", %{base: base, bare: bare} do
      wt_path = Path.join(base, "deep/nested/worktree")
      assert :ok = Worktree.create(bare, wt_path, "work-branch")
      assert File.dir?(wt_path)
    end
  end

  describe "list/1" do
    test "returns the bare worktree entry at minimum", %{bare: bare} do
      {:ok, worktrees} = Worktree.list(bare)
      assert is_list(worktrees)
      assert length(worktrees) >= 1
    end

    test "shows newly created worktree", %{base: base, bare: bare} do
      wt_path = Path.join(base, "wt_listed")
      :ok = Worktree.create(bare, wt_path, "work-branch")

      {:ok, worktrees} = Worktree.list(bare)
      paths = Enum.map(worktrees, & &1.path)
      assert wt_path in paths
    end
  end

  describe "remove/2" do
    test "removes worktree directory", %{base: base, bare: bare} do
      wt_path = Path.join(base, "wt_to_remove")
      :ok = Worktree.create(bare, wt_path, "work-branch")
      assert File.dir?(wt_path)

      assert :ok = Worktree.remove(bare, wt_path)
      refute File.dir?(wt_path)
    end
  end

  describe "prune/1" do
    test "prune runs without error", %{bare: bare} do
      assert :ok = Worktree.prune(bare)
    end

    test "prune after remove cleans up stale entry", %{base: base, bare: bare} do
      wt_path = Path.join(base, "wt_prune")
      :ok = Worktree.create(bare, wt_path, "work-branch")
      :ok = Worktree.remove(bare, wt_path)
      assert :ok = Worktree.prune(bare)
    end
  end
end
