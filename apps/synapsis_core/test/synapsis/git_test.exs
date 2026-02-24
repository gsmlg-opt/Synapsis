defmodule Synapsis.GitTest do
  use ExUnit.Case

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "synapsis_git_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    # Initialize a git repo in the tmp dir
    System.cmd("git", ["init"], cd: tmp_dir)
    System.cmd("git", ["config", "user.email", "test@test.com"], cd: tmp_dir)
    System.cmd("git", ["config", "user.name", "Test"], cd: tmp_dir)

    # Create initial commit
    File.write!(Path.join(tmp_dir, "README.md"), "# Test")
    System.cmd("git", ["add", "."], cd: tmp_dir)
    System.cmd("git", ["commit", "-m", "initial"], cd: tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, path: tmp_dir}
  end

  test "diff/1 returns empty string for clean repo", %{path: path} do
    assert {:ok, output} = Synapsis.Git.diff(path)
    assert String.trim(output) == ""
  end

  test "diff/1 shows changes for modified files", %{path: path} do
    File.write!(Path.join(path, "README.md"), "# Modified")
    assert {:ok, output} = Synapsis.Git.diff(path)
    assert output =~ "Modified"
  end

  test "diff/2 accepts extra args like --stat", %{path: path} do
    File.write!(Path.join(path, "README.md"), "# Modified")
    System.cmd("git", ["add", "."], cd: path)
    assert {:ok, output} = Synapsis.Git.diff(path, args: ["--staged", "--stat"])
    assert output =~ "README.md"
  end

  test "is_repo?/1 returns true for git repos", %{path: path} do
    assert Synapsis.Git.is_repo?(path)
  end

  test "is_repo?/1 returns false for non-git dirs" do
    non_git = Path.join(System.tmp_dir!(), "not_git_#{System.unique_integer([:positive])}")
    File.mkdir_p!(non_git)
    on_exit(fn -> File.rm_rf!(non_git) end)
    refute Synapsis.Git.is_repo?(non_git)
  end

  test "checkpoint/2 creates a commit", %{path: path} do
    File.write!(Path.join(path, "new_file.txt"), "content")
    assert {:ok, _} = Synapsis.Git.checkpoint(path)
  end

  test "checkpoint/2 does nothing when clean", %{path: path} do
    assert {:ok, "nothing to commit"} = Synapsis.Git.checkpoint(path)
  end

  test "last_commit_message/1 returns the latest message", %{path: path} do
    File.write!(Path.join(path, "test.txt"), "data")
    Synapsis.Git.checkpoint(path, "synapsis test-msg")

    assert {:ok, "synapsis test-msg"} = Synapsis.Git.last_commit_message(path)
  end

  test "undo_last/1 undoes a synapsis commit", %{path: path} do
    File.write!(Path.join(path, "undo_test.txt"), "data")
    {:ok, _} = Synapsis.Git.checkpoint(path, "synapsis auto-checkpoint")

    assert {:ok, _} = Synapsis.Git.undo_last(path)
  end

  test "undo_last/1 refuses to undo non-synapsis commits", %{path: path} do
    assert {:error, _} = Synapsis.Git.undo_last(path)
  end

  test "is_repo?/1 returns false for non-existent path" do
    refute Synapsis.Git.is_repo?("/tmp/does_not_exist_#{System.unique_integer([:positive])}")
  end

  test "checkpoint/2 with custom message", %{path: path} do
    File.write!(Path.join(path, "custom_msg.txt"), "data")
    assert {:ok, _} = Synapsis.Git.checkpoint(path, "synapsis custom-checkpoint")
    assert {:ok, "synapsis custom-checkpoint"} = Synapsis.Git.last_commit_message(path)
  end

  test "multiple checkpoints create separate commits", %{path: path} do
    File.write!(Path.join(path, "first.txt"), "a")
    {:ok, _} = Synapsis.Git.checkpoint(path, "synapsis first")

    File.write!(Path.join(path, "second.txt"), "b")
    {:ok, _} = Synapsis.Git.checkpoint(path, "synapsis second")

    assert {:ok, "synapsis second"} = Synapsis.Git.last_commit_message(path)
  end
end
