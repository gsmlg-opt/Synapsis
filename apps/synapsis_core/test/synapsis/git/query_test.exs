defmodule Synapsis.Git.QueryTest do
  use ExUnit.Case, async: true

  alias Synapsis.Git.{Branch, Diff, Log, Status, Worktree}

  # Full test setup:
  # 1. source repo with initial commit
  # 2. bare clone
  # 3. branch created in bare
  # 4. worktree checked out on that branch
  # 5. a new commit made in the worktree
  # 6. an untracked file left in the worktree
  defp full_setup(base) do
    # Source repo
    src = Path.join(base, "src")
    File.mkdir_p!(src)
    System.cmd("git", ["init"], cd: src)
    System.cmd("git", ["config", "user.email", "test@test.com"], cd: src)
    System.cmd("git", ["config", "user.name", "Test User"], cd: src)
    File.write!(Path.join(src, "README.md"), "# Source")
    System.cmd("git", ["add", "."], cd: src)
    System.cmd("git", ["commit", "-m", "initial commit"], cd: src)

    # Bare clone
    bare = Path.join(base, "bare.git")
    System.cmd("git", ["clone", "--bare", src, bare])

    # Find the default branch name
    {branches_out, 0} = System.cmd("git", ["branch", "--format=%(refname:short)"], cd: bare)
    default_branch = branches_out |> String.split("\n", trim: true) |> List.first()

    # Feature branch
    :ok = Branch.create(bare, "feature", default_branch)

    # Worktree on feature branch
    wt = Path.join(base, "worktree")
    :ok = Worktree.create(bare, wt, "feature")

    # Configure git in the worktree
    System.cmd("git", ["config", "user.email", "test@test.com"], cd: wt)
    System.cmd("git", ["config", "user.name", "Test User"], cd: wt)

    # A new file committed in the worktree
    File.write!(Path.join(wt, "new_file.txt"), "hello world\n")
    System.cmd("git", ["add", "new_file.txt"], cd: wt)
    System.cmd("git", ["commit", "-m", "add new_file"], cd: wt)

    # An untracked file
    File.write!(Path.join(wt, "untracked.txt"), "not staged\n")

    %{src: src, bare: bare, wt: wt, default_branch: default_branch}
  end

  setup do
    base =
      Path.join(System.tmp_dir!(), "query_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    ctx = full_setup(base)
    {:ok, ctx}
  end

  # ---- Log ----

  describe "Log.recent/2" do
    test "returns commits with parsed fields", %{wt: wt} do
      assert {:ok, commits} = Log.recent(wt)
      assert length(commits) >= 2

      first = hd(commits)
      assert Map.has_key?(first, :hash)
      assert Map.has_key?(first, :subject)
      assert Map.has_key?(first, :author)
      assert Map.has_key?(first, :date)

      assert String.length(first.hash) == 40
      assert first.subject == "add new_file"
      assert first.author == "Test User"
    end

    test "respects limit option", %{wt: wt} do
      assert {:ok, commits} = Log.recent(wt, limit: 1)
      assert length(commits) == 1
      assert hd(commits).subject == "add new_file"
    end

    test "respects branch option", %{wt: wt} do
      assert {:ok, commits} = Log.recent(wt, branch: "HEAD", limit: 5)
      assert length(commits) >= 1
    end
  end

  # ---- Diff ----

  describe "Diff.from_base/2" do
    test "returns diff containing the new file", %{wt: wt, default_branch: base_branch} do
      # The worktree is checked out from a bare clone (no remotes), so the
      # default branch is available as a local ref.
      assert {:ok, diff} = Diff.from_base(wt, base_branch)
      assert String.contains?(diff, "new_file.txt")
    end

    test "returns empty diff when no commits ahead of base", %{wt: wt} do
      # _base_branch unused in this test
      # Diff of HEAD against itself should be empty
      assert {:ok, diff} = Diff.from_base(wt, "HEAD")
      assert String.trim(diff) == ""
    end
  end

  describe "Diff.stat/2" do
    test "returns file count and insertions", %{wt: wt, default_branch: base_branch} do
      assert {:ok, stat} = Diff.stat(wt, base_branch)
      assert stat.files_changed == 1
      assert stat.insertions == 1
      assert stat.deletions == 0
    end
  end

  # ---- Status ----

  describe "Status.summary/1" do
    test "returns untracked file in untracked list", %{wt: wt} do
      assert {:ok, status} = Status.summary(wt)
      assert is_list(status.untracked)
      assert "untracked.txt" in status.untracked
    end

    test "returns empty staged and modified for clean state", %{wt: wt} do
      # Remove the untracked file to get a truly clean working tree
      File.rm!(Path.join(wt, "untracked.txt"))
      assert {:ok, status} = Status.summary(wt)
      assert status.staged == []
      assert status.modified == []
      assert status.untracked == []
    end

    test "returns staged file after git add", %{wt: wt} do
      File.write!(Path.join(wt, "staged_file.txt"), "staged\n")
      System.cmd("git", ["add", "staged_file.txt"], cd: wt)
      assert {:ok, status} = Status.summary(wt)
      assert "staged_file.txt" in status.staged
    end

    test "returns modified file", %{wt: wt} do
      File.write!(Path.join(wt, "README.md"), "modified\n")
      assert {:ok, status} = Status.summary(wt)
      assert "README.md" in status.modified
    end
  end
end
