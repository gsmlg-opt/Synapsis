defmodule Synapsis.Tool.ToolsTest do
  use ExUnit.Case

  alias Synapsis.Tool.{
    FileRead,
    FileEdit,
    FileWrite,
    Bash,
    Grep,
    Glob,
    ListDir,
    FileDelete,
    FileMove
  }

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
      {:ok, content} = FileRead.execute(%{"path" => "hello.txt"}, %{project_path: @test_dir})
      assert content =~ "Hello World"
    end

    test "reads with offset and limit" do
      {:ok, content} =
        FileRead.execute(
          %{"path" => "hello.txt", "offset" => 1, "limit" => 1},
          %{project_path: @test_dir}
        )

      assert content == "Line 2"
    end

    test "returns error for missing file" do
      {:error, msg} = FileRead.execute(%{"path" => "nonexistent.txt"}, %{project_path: @test_dir})
      assert msg =~ "not found"
    end

    test "rejects path outside project root" do
      {:error, msg} = FileRead.execute(%{"path" => "/etc/passwd"}, %{project_path: @test_dir})
      assert msg =~ "outside project root"
    end

    test "rejects sibling-directory path traversal" do
      # Sibling dir: @test_dir is e.g. /tmp/synapsis_tool_test_12345
      # sibling would be /tmp/synapsis_tool_test_12345_evil
      sibling = @test_dir <> "_evil"
      {:error, msg} = FileRead.execute(%{"path" => sibling}, %{project_path: @test_dir})
      assert msg =~ "outside project root"
    end

    test "reads with offset zero returns all lines" do
      {:ok, content} =
        FileRead.execute(
          %{"path" => "hello.txt", "offset" => 0},
          %{project_path: @test_dir}
        )

      assert content =~ "Hello World"
      assert content =~ "Line 2"
    end

  end

  describe "FileWrite" do
    test "writes a new file" do
      {:ok, msg} =
        FileWrite.execute(
          %{"path" => "new_file.txt", "content" => "new content"},
          %{project_path: @test_dir}
        )

      assert msg =~ "Successfully wrote"
      assert File.read!(Path.join(@test_dir, "new_file.txt")) == "new content"
    end

    test "creates directories as needed" do
      {:ok, _} =
        FileWrite.execute(
          %{"path" => "deep/dir/file.txt", "content" => "deep content"},
          %{project_path: @test_dir}
        )

      assert File.exists?(Path.join(@test_dir, "deep/dir/file.txt"))
    end

    test "declares file_changed side effect" do
      assert :file_changed in FileWrite.side_effects()
    end
  end

  describe "FileEdit" do
    test "replaces content in file" do
      test_file = Path.join(@test_dir, "edit_test.txt")
      File.write!(test_file, "foo bar baz")

      {:ok, msg} =
        FileEdit.execute(
          %{"path" => "edit_test.txt", "old_string" => "bar", "new_string" => "qux"},
          %{project_path: @test_dir}
        )

      assert msg =~ "Successfully edited"
      assert File.read!(test_file) == "foo qux baz"
    end

    test "returns error when string not found" do
      {:error, msg} =
        FileEdit.execute(
          %{"path" => "hello.txt", "old_string" => "NONEXISTENT", "new_string" => "x"},
          %{project_path: @test_dir}
        )

      assert msg =~ "not found"
    end

    test "declares file_changed side effect" do
      assert :file_changed in FileEdit.side_effects()
    end
  end

  describe "Bash" do
    test "executes a simple command" do
      {:ok, output} = Bash.execute(%{"command" => "echo hello"}, %{project_path: @test_dir})
      assert output == "hello"
    end

    test "returns exit code for failing command" do
      {:ok, output} = Bash.execute(%{"command" => "exit 1"}, %{project_path: @test_dir})
      assert output =~ "Exit code: 1"
    end

    test "uses project directory as cwd" do
      {:ok, output} = Bash.execute(%{"command" => "ls hello.txt"}, %{project_path: @test_dir})
      assert output =~ "hello.txt"
    end

    test "has no side effects by default" do
      assert Bash.side_effects() == []
    end

    test "caps timeout at 300_000ms when caller passes larger value" do
      # Large timeout should be capped, not cause issues
      {:ok, output} =
        Bash.execute(
          %{"command" => "echo capped", "timeout" => 999_999_999},
          %{project_path: @test_dir}
        )

      assert output == "capped"
    end

    test "returns ok with truncation message for large output" do
      # Generate ~11MB output to trigger 10MB truncation cap
      # Use seq to produce many lines without storing them
      cmd = "dd if=/dev/zero bs=1024 count=11000 2>/dev/null | tr '\\0' 'x'"

      {:ok, output} = Bash.execute(%{"command" => cmd}, %{project_path: @test_dir})
      assert output =~ "[Output truncated at 10MB]"
    end
  end

  describe "Grep" do
    test "searches for pattern" do
      {:ok, output} = Grep.execute(%{"pattern" => "Hello"}, %{project_path: @test_dir})
      assert output =~ "hello.txt"
    end

    test "returns no matches message" do
      {:ok, output} = Grep.execute(%{"pattern" => "ZZZNONEXISTENT"}, %{project_path: @test_dir})
      assert output =~ "No matches"
    end

    test "rejects path traversal outside project root" do
      {:error, msg} =
        Grep.execute(%{"pattern" => "root", "path" => "../../../../etc"}, %{
          project_path: @test_dir
        })

      assert msg =~ "outside project root"
    end
  end

  describe "Glob" do
    test "finds files by pattern" do
      {:ok, output} = Glob.execute(%{"pattern" => "**/*.txt"}, %{project_path: @test_dir})
      assert output =~ "hello.txt"
    end

    test "finds nested files" do
      {:ok, output} = Glob.execute(%{"pattern" => "**/*.txt"}, %{project_path: @test_dir})
      assert output =~ "nested.txt"
    end

    test "returns no matches message" do
      {:ok, output} = Glob.execute(%{"pattern" => "**/*.xyz"}, %{project_path: @test_dir})
      assert output =~ "No files matched"
    end

    test "rejects base path outside project root" do
      {:error, msg} =
        Glob.execute(%{"pattern" => "*", "path" => "/etc"}, %{project_path: @test_dir})

      assert msg =~ "outside project root"
    end
  end

  describe "ListDir" do
    test "lists directory contents" do
      {:ok, output} = ListDir.execute(%{"path" => "."}, %{project_path: @test_dir})
      assert output =~ "hello.txt"
      assert output =~ "sub/"
    end

    test "lists with depth" do
      {:ok, output} = ListDir.execute(%{"path" => ".", "depth" => 2}, %{project_path: @test_dir})
      assert output =~ "nested.txt"
    end

    test "returns error for missing directory" do
      {:error, msg} = ListDir.execute(%{"path" => "nonexistent"}, %{project_path: @test_dir})
      assert msg =~ "not found" or msg =~ "does not exist"
    end

    test "rejects path traversal outside project root" do
      {:error, msg} = ListDir.execute(%{"path" => "/etc"}, %{project_path: @test_dir})
      assert msg =~ "outside project root"
    end

    test "rejects relative path traversal" do
      {:error, msg} =
        ListDir.execute(%{"path" => "../../../../../../etc"}, %{project_path: @test_dir})

      assert msg =~ "outside project root"
    end
  end

  describe "FileDelete" do
    test "deletes a file" do
      delete_path = Path.join(@test_dir, "to_delete.txt")
      File.write!(delete_path, "delete me")

      {:ok, msg} =
        FileDelete.execute(%{"path" => "to_delete.txt"}, %{project_path: @test_dir})

      assert msg =~ "deleted"
      refute File.exists?(delete_path)
    end

    test "returns error for missing file" do
      {:error, msg} =
        FileDelete.execute(%{"path" => "nonexistent_del.txt"}, %{project_path: @test_dir})

      assert msg =~ "not found" or msg =~ "does not exist"
    end

    test "declares file_changed side effect" do
      assert :file_changed in FileDelete.side_effects()
    end
  end

  describe "FileMove" do
    test "moves a file" do
      source = Path.join(@test_dir, "move_source.txt")
      File.write!(source, "move me")

      {:ok, msg} =
        FileMove.execute(
          %{"source" => "move_source.txt", "destination" => "move_dest.txt"},
          %{project_path: @test_dir}
        )

      assert msg =~ "Moved"
      refute File.exists?(source)
      assert File.exists?(Path.join(@test_dir, "move_dest.txt"))
    end

    test "returns error for missing source" do
      {:error, msg} =
        FileMove.execute(
          %{"source" => "no_exist.txt", "destination" => "dest.txt"},
          %{project_path: @test_dir}
        )

      assert msg =~ "not found" or msg =~ "does not exist"
    end

    test "declares file_changed side effect" do
      assert :file_changed in FileMove.side_effects()
    end
  end
end
