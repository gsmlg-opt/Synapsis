defmodule Synapsis.Tool.BashTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.Bash

  @tag :tmp_dir
  test "executes simple command", %{tmp_dir: tmp_dir} do
    {:ok, output} = Bash.execute(%{"command" => "echo hello"}, %{project_path: tmp_dir})
    assert output =~ "hello"
  end

  @tag :tmp_dir
  test "captures non-zero exit code in output", %{tmp_dir: tmp_dir} do
    {:ok, output} = Bash.execute(%{"command" => "exit 42"}, %{project_path: tmp_dir})
    assert output =~ "Exit code: 42"
  end

  @tag :tmp_dir
  test "respects working directory", %{tmp_dir: tmp_dir} do
    {:ok, output} = Bash.execute(%{"command" => "pwd"}, %{project_path: tmp_dir})
    assert output =~ tmp_dir
  end

  @tag :tmp_dir
  test "handles timeout", %{tmp_dir: tmp_dir} do
    {:error, msg} =
      Bash.execute(
        %{"command" => "sleep 60", "timeout" => 500},
        %{project_path: tmp_dir}
      )

    assert msg =~ "timed out"
  end

  @tag :tmp_dir
  test "captures stderr merged with stdout", %{tmp_dir: tmp_dir} do
    {:ok, output} =
      Bash.execute(
        %{"command" => "echo out && echo err >&2"},
        %{project_path: tmp_dir}
      )

    assert output =~ "out"
    assert output =~ "err"
  end

  test "declares execute permission and execution category" do
    assert Bash.permission_level() == :execute
    assert Bash.category() == :execution
  end
end
