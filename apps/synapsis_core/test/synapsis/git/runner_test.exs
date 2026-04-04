defmodule Synapsis.Git.RunnerTest do
  use ExUnit.Case, async: true

  alias Synapsis.Git.Runner

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "runner_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    # Create a real git repo so commands that need a repo work
    System.cmd("git", ["init"], cd: tmp_dir)
    System.cmd("git", ["config", "user.email", "test@test.com"], cd: tmp_dir)
    System.cmd("git", ["config", "user.name", "Test"], cd: tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, tmp: tmp_dir}
  end

  test "run/2 returns stdout on success with git --version", %{tmp: tmp} do
    assert {:ok, output} = Runner.run(tmp, ["--version"])
    assert String.contains?(output, "git version")
  end

  test "run/2 returns error for invalid working directory" do
    assert {:error, reason} = Runner.run("/nonexistent_path_#{System.unique_integer()}", ["--version"])
    assert is_binary(reason)
  end

  test "run/3 respects custom timeout", %{tmp: tmp} do
    # Using a huge timeout should still work for fast commands
    assert {:ok, _output} = Runner.run(tmp, ["--version"], timeout: 60_000)
  end

  test "run/2 returns error on non-zero exit code", %{tmp: tmp} do
    assert {:error, reason} = Runner.run(tmp, ["invalid-git-command-xyz"])
    assert String.contains?(reason, "git exited with")
  end
end
