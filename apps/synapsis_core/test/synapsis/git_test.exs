defmodule Synapsis.GitTest do
  use ExUnit.Case, async: false

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

  test "status reports tracked and untracked changes without creating refs or objects", %{
    tmp_dir: dir
  } do
    File.write!(Path.join(dir, "a.txt"), "dirty\n")
    File.write!(Path.join(dir, "untracked.txt"), "new\n")
    refs_before = git!(dir, ["show-ref"])
    objects_before = git!(dir, ["count-objects", "-v"])

    assert {:ok, %{head: head, dirty: true}} = Git.status(dir)
    assert head =~ ~r/^[0-9a-f]{40}$/

    File.write!(Path.join(dir, "a.txt"), "original\n")
    assert {:ok, %{dirty: true}} = Git.status(dir)

    assert git!(dir, ["show-ref"]) == refs_before
    assert git!(dir, ["count-objects", "-v"]) == objects_before
  end

  test "status returns dirty on the first output chunk without collecting the tail", %{
    tmp_dir: dir
  } do
    fake_bin = Path.join(dir, "fake-bin")
    fake_git = Path.join(fake_bin, "git")
    File.mkdir_p!(fake_bin)

    File.write!(
      fake_git,
      """
      #!/bin/sh
      case "$1" in
        rev-parse)
          printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\\n'
          ;;
        status)
          printf '?'
          sleep 2
          head -c 1048576 /dev/zero 2>/dev/null | tr '\\000' x 2>/dev/null
          ;;
        *)
          exit 1
          ;;
      esac
      """
    )

    File.chmod!(fake_git, 0o700)
    previous_path = System.fetch_env!("PATH")
    System.put_env("PATH", fake_bin <> ":" <> previous_path)
    on_exit(fn -> System.put_env("PATH", previous_path) end)

    started_at = System.monotonic_time(:millisecond)

    assert {:ok, %{head: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", dirty: true}} =
             Git.status(dir)

    assert System.monotonic_time(:millisecond) - started_at < 1_000
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
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    out
  end
end
