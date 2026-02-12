defmodule Synapsis.Tool.ToolsTest do
  use ExUnit.Case

  alias Synapsis.Tool.{FileRead, FileEdit, FileWrite, Bash, Grep, Glob}

  @test_dir System.tmp_dir!() |> Path.join("synapsis_tool_test_#{:rand.uniform(100_000)}")

  setup_all do
    File.mkdir_p!(@test_dir)
    File.write!(Path.join(@test_dir, "hello.txt"), "Hello World\nLine 2\nLine 3\n")

    File.write!(
      Path.join(@test_dir, "code.ex"),
      "defmodule Test do\n  def hello, do: :world\nend\n"
    )

    File.mkdir_p!(Path.join(@test_dir, "sub"))
    File.write!(Path.join(@test_dir, "sub/nested.txt"), "nested content")

    on_exit(fn -> File.rm_rf!(@test_dir) end)
    :ok
  end

  describe "FileRead" do
    test "reads a file" do
      {:ok, content} = FileRead.call(%{"path" => "hello.txt"}, %{project_path: @test_dir})
      assert content =~ "Hello World"
    end

    test "reads with offset and limit" do
      {:ok, content} =
        FileRead.call(
          %{"path" => "hello.txt", "offset" => 1, "limit" => 1},
          %{project_path: @test_dir}
        )

      assert content == "Line 2"
    end

    test "returns error for missing file" do
      {:error, msg} = FileRead.call(%{"path" => "nonexistent.txt"}, %{project_path: @test_dir})
      assert msg =~ "not found"
    end

    test "rejects path outside project root" do
      {:error, msg} = FileRead.call(%{"path" => "/etc/passwd"}, %{project_path: @test_dir})
      assert msg =~ "outside project root"
    end
  end

  describe "FileWrite" do
    test "writes a new file" do
      {:ok, msg} =
        FileWrite.call(
          %{"path" => "new_file.txt", "content" => "new content"},
          %{project_path: @test_dir}
        )

      assert msg =~ "Successfully wrote"
      assert File.read!(Path.join(@test_dir, "new_file.txt")) == "new content"
    end

    test "creates directories as needed" do
      {:ok, _} =
        FileWrite.call(
          %{"path" => "deep/dir/file.txt", "content" => "deep content"},
          %{project_path: @test_dir}
        )

      assert File.exists?(Path.join(@test_dir, "deep/dir/file.txt"))
    end
  end

  describe "FileEdit" do
    test "replaces content in file" do
      test_file = Path.join(@test_dir, "edit_test.txt")
      File.write!(test_file, "foo bar baz")

      {:ok, msg} =
        FileEdit.call(
          %{"path" => "edit_test.txt", "old_string" => "bar", "new_string" => "qux"},
          %{project_path: @test_dir}
        )

      assert msg =~ "Successfully edited"
      assert File.read!(test_file) == "foo qux baz"
    end

    test "returns error when string not found" do
      {:error, msg} =
        FileEdit.call(
          %{"path" => "hello.txt", "old_string" => "NONEXISTENT", "new_string" => "x"},
          %{project_path: @test_dir}
        )

      assert msg =~ "not found"
    end
  end

  describe "Bash" do
    test "executes a simple command" do
      {:ok, output} = Bash.call(%{"command" => "echo hello"}, %{project_path: @test_dir})
      assert output == "hello"
    end

    test "returns exit code for failing command" do
      {:ok, output} = Bash.call(%{"command" => "exit 1"}, %{project_path: @test_dir})
      assert output =~ "Exit code: 1"
    end

    test "uses project directory as cwd" do
      {:ok, output} = Bash.call(%{"command" => "ls hello.txt"}, %{project_path: @test_dir})
      assert output =~ "hello.txt"
    end
  end

  describe "Grep" do
    test "searches for pattern" do
      {:ok, output} = Grep.call(%{"pattern" => "Hello"}, %{project_path: @test_dir})
      assert output =~ "hello.txt"
    end

    test "returns no matches message" do
      {:ok, output} = Grep.call(%{"pattern" => "ZZZNONEXISTENT"}, %{project_path: @test_dir})
      assert output =~ "No matches"
    end
  end

  describe "Glob" do
    test "finds files by pattern" do
      {:ok, output} = Glob.call(%{"pattern" => "**/*.txt"}, %{project_path: @test_dir})
      assert output =~ "hello.txt"
    end

    test "finds nested files" do
      {:ok, output} = Glob.call(%{"pattern" => "**/*.txt"}, %{project_path: @test_dir})
      assert output =~ "nested.txt"
    end

    test "returns no matches message" do
      {:ok, output} = Glob.call(%{"pattern" => "**/*.xyz"}, %{project_path: @test_dir})
      assert output =~ "No files matched"
    end
  end
end
