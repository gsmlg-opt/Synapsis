defmodule Synapsis.GitTest do
  use ExUnit.Case, async: true

  alias Synapsis.Git

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    git!(tmp_dir, ["init", "-q"])
    git!(tmp_dir, ["config", "user.email", "test@synapsis.local"])
    git!(tmp_dir, ["config", "user.name", "Synapsis Test"])
    File.write!(Path.join(tmp_dir, "a.txt"), "original\n")
    git!(tmp_dir, ["add", "."])
    git!(tmp_dir, ["commit", "-q", "-m", "init"])
    :ok
  end

  test "capture_ref returns head and no stash for a clean tree", %{tmp_dir: dir} do
    assert {:ok, %{head: head, stash: nil}} = Git.capture_ref(dir)
    assert head =~ ~r/^[0-9a-f]{40}$/
  end

  test "capture_ref records dirty state without modifying the tree", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "a.txt"), "dirty\n")

    assert {:ok, %{stash: stash}} = Git.capture_ref(dir)
    assert is_binary(stash)
    assert File.read!(Path.join(dir, "a.txt")) == "dirty\n"
  end

  test "restore_ref discards tracked changes made after capture", %{tmp_dir: dir} do
    assert {:ok, ref} = Git.capture_ref(dir)

    File.write!(Path.join(dir, "a.txt"), "corrupted by failed patch\n")

    assert :ok = Git.restore_ref(dir, ref)
    assert File.read!(Path.join(dir, "a.txt")) == "original\n"
  end

  test "restore_ref reapplies dirty state captured at checkpoint time", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "a.txt"), "dirty\n")
    assert {:ok, ref} = Git.capture_ref(dir)

    File.write!(Path.join(dir, "a.txt"), "corrupted\n")

    assert :ok = Git.restore_ref(dir, ref)
    assert File.read!(Path.join(dir, "a.txt")) == "dirty\n"
  end

  test "capture_ref rejects a non-git directory", %{tmp_dir: dir} do
    plain = Path.join(dir, "plain")
    File.mkdir_p!(plain)

    assert {:error, :not_a_git_repo} = Git.capture_ref(plain)
  end

  defp git!(dir, args) do
    {_out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
  end
end
