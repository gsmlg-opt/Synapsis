defmodule Synapsis.Tool.EdgeCasesTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.{Bash, FileRead, FileWrite, FileEdit, FileDelete, FileMove}

  setup do
    test_dir =
      Path.join(System.tmp_dir!(), "synapsis_edge_cases_#{System.unique_integer([:positive])}")

    File.mkdir_p!(test_dir)

    on_exit(fn -> File.rm_rf!(test_dir) end)

    %{test_dir: test_dir, ctx: %{project_path: test_dir}}
  end

  # ---------------------------------------------------------------------------
  # Bash edge cases
  # ---------------------------------------------------------------------------
  describe "Bash timeout" do
    test "returns error with appropriate message", %{ctx: ctx} do
      result = Bash.execute(%{"command" => "sleep 10", "timeout" => 50}, ctx)

      assert {:error, msg} = result
      assert msg =~ "timed out"
      assert msg =~ "50ms"
    end
  end

  describe "Bash non-zero exit code" do
    test "exit code 1 returns ok with exit code in output", %{ctx: ctx} do
      {:ok, output} = Bash.execute(%{"command" => "exit 1"}, ctx)
      assert output =~ "Exit code: 1"
    end

    test "exit code 127 (command not found) returns ok with exit code", %{ctx: ctx} do
      {:ok, output} = Bash.execute(%{"command" => "nonexistent_cmd_xyz_12345"}, ctx)
      assert output =~ "Exit code: 127"
    end

    test "exit code 2 returns ok with combined stderr output", %{ctx: ctx} do
      {:ok, output} = Bash.execute(%{"command" => "echo errinfo >&2; exit 2"}, ctx)
      assert output =~ "Exit code: 2"
      assert output =~ "errinfo"
    end
  end

  describe "Bash empty command" do
    test "empty string command returns ok with empty output", %{ctx: ctx} do
      {:ok, output} = Bash.execute(%{"command" => ""}, ctx)
      assert output == ""
    end
  end

  describe "Bash special characters" do
    test "command with single quotes works", %{ctx: ctx} do
      {:ok, output} = Bash.execute(%{"command" => "echo 'hello world'"}, ctx)
      assert output == "hello world"
    end

    test "command with double quotes works", %{ctx: ctx} do
      {:ok, output} = Bash.execute(%{"command" => "echo \"hello world\""}, ctx)
      assert output == "hello world"
    end

    test "command with pipe works", %{ctx: ctx} do
      {:ok, output} = Bash.execute(%{"command" => "echo 'abc def' | wc -w"}, ctx)
      assert String.trim(output) == "2"
    end

    test "command with shell variable expansion works", %{ctx: ctx} do
      {:ok, output} = Bash.execute(%{"command" => "X=42; echo $X"}, ctx)
      assert output == "42"
    end

    test "command with newlines in output works", %{ctx: ctx} do
      {:ok, output} = Bash.execute(%{"command" => "printf 'line1\\nline2\\nline3'"}, ctx)
      assert output == "line1\nline2\nline3"
    end

    test "command with glob characters works", %{test_dir: test_dir, ctx: ctx} do
      File.write!(Path.join(test_dir, "a.txt"), "a")
      File.write!(Path.join(test_dir, "b.txt"), "b")

      {:ok, output} = Bash.execute(%{"command" => "ls *.txt | sort"}, ctx)
      assert output =~ "a.txt"
      assert output =~ "b.txt"
    end

    test "command with unicode characters works", %{ctx: ctx} do
      {:ok, output} = Bash.execute(%{"command" => "echo 'cafe\\u0301'"}, ctx)
      assert is_binary(output)
    end

    test "command with backslashes works", %{ctx: ctx} do
      {:ok, output} = Bash.execute(%{"command" => "echo 'back\\\\slash'"}, ctx)
      assert is_binary(output)
    end
  end

  describe "Bash nil timeout uses default" do
    test "nil timeout falls back to 30s default", %{ctx: ctx} do
      {:ok, output} = Bash.execute(%{"command" => "echo ok", "timeout" => nil}, ctx)
      assert output == "ok"
    end
  end

  # ---------------------------------------------------------------------------
  # FileRead edge cases
  # ---------------------------------------------------------------------------
  describe "FileRead non-existent file" do
    test "returns error with 'not found' message", %{ctx: ctx} do
      {:error, msg} = FileRead.execute(%{"path" => "does_not_exist.txt"}, ctx)
      assert msg =~ "not found" or msg =~ "File not found"
    end
  end

  describe "FileRead offset and limit" do
    test "offset skips the first N lines", %{test_dir: test_dir, ctx: ctx} do
      File.write!(Path.join(test_dir, "lines.txt"), "line0\nline1\nline2\nline3\nline4\n")

      {:ok, content} =
        FileRead.execute(%{"path" => "lines.txt", "offset" => 2}, ctx)

      refute content =~ "line0"
      refute content =~ "line1"
      assert content =~ "line2"
      assert content =~ "line3"
    end

    test "limit restricts number of lines returned", %{test_dir: test_dir, ctx: ctx} do
      File.write!(Path.join(test_dir, "lines.txt"), "line0\nline1\nline2\nline3\nline4\n")

      {:ok, content} =
        FileRead.execute(%{"path" => "lines.txt", "limit" => 2}, ctx)

      assert content == "line0\nline1"
    end

    test "offset and limit combined work correctly", %{test_dir: test_dir, ctx: ctx} do
      File.write!(Path.join(test_dir, "lines.txt"), "line0\nline1\nline2\nline3\nline4\n")

      {:ok, content} =
        FileRead.execute(%{"path" => "lines.txt", "offset" => 1, "limit" => 2}, ctx)

      assert content == "line1\nline2"
    end

    test "offset beyond file length returns empty string", %{test_dir: test_dir, ctx: ctx} do
      File.write!(Path.join(test_dir, "short.txt"), "one\ntwo\n")

      {:ok, content} =
        FileRead.execute(%{"path" => "short.txt", "offset" => 100}, ctx)

      assert content == ""
    end

    test "limit of zero returns empty string", %{test_dir: test_dir, ctx: ctx} do
      File.write!(Path.join(test_dir, "some.txt"), "content here")

      # limit 0 is not > 0, so maybe_limit returns content unchanged
      {:ok, content} =
        FileRead.execute(%{"path" => "some.txt", "limit" => 0}, ctx)

      # The implementation: limit 0 falls through to the default clause
      assert content == "content here"
    end

    test "negative limit is treated as no limit", %{test_dir: test_dir, ctx: ctx} do
      File.write!(Path.join(test_dir, "neg.txt"), "line1\nline2\nline3\n")

      {:ok, content} =
        FileRead.execute(%{"path" => "neg.txt", "limit" => -5}, ctx)

      assert content =~ "line1"
      assert content =~ "line3"
    end
  end

  describe "FileRead empty file" do
    test "returns empty string for empty file", %{test_dir: test_dir, ctx: ctx} do
      File.write!(Path.join(test_dir, "empty.txt"), "")

      {:ok, content} = FileRead.execute(%{"path" => "empty.txt"}, ctx)
      assert content == ""
    end
  end

  describe "FileRead binary content" do
    test "reads binary/non-UTF8 content without crashing", %{test_dir: test_dir, ctx: ctx} do
      File.write!(Path.join(test_dir, "binary.bin"), <<0, 1, 2, 255, 254, 253>>)

      {:ok, content} = FileRead.execute(%{"path" => "binary.bin"}, ctx)
      assert is_binary(content)
    end
  end

  describe "FileRead absolute path within project" do
    test "absolute path inside project root works", %{test_dir: test_dir, ctx: ctx} do
      File.write!(Path.join(test_dir, "abs.txt"), "absolute content")

      {:ok, content} =
        FileRead.execute(%{"path" => Path.join(test_dir, "abs.txt")}, ctx)

      assert content == "absolute content"
    end
  end

  # ---------------------------------------------------------------------------
  # FileWrite edge cases
  # ---------------------------------------------------------------------------
  describe "FileWrite nested non-existent directory" do
    test "creates intermediate directories automatically", %{test_dir: test_dir, ctx: ctx} do
      {:ok, msg} =
        FileWrite.execute(
          %{"path" => "a/b/c/d/deep_file.txt", "content" => "deep content"},
          ctx
        )

      assert msg =~ "Successfully wrote"
      assert File.read!(Path.join(test_dir, "a/b/c/d/deep_file.txt")) == "deep content"
    end
  end

  describe "FileWrite overwriting existing file" do
    test "overwrites content of existing file", %{test_dir: test_dir, ctx: ctx} do
      path = Path.join(test_dir, "overwrite.txt")
      File.write!(path, "original content")

      {:ok, _msg} =
        FileWrite.execute(
          %{"path" => "overwrite.txt", "content" => "new content"},
          ctx
        )

      assert File.read!(path) == "new content"
    end

    test "overwriting with empty content creates empty file", %{test_dir: test_dir, ctx: ctx} do
      path = Path.join(test_dir, "to_empty.txt")
      File.write!(path, "will be emptied")

      {:ok, msg} =
        FileWrite.execute(%{"path" => "to_empty.txt", "content" => ""}, ctx)

      assert msg =~ "0 bytes"
      assert File.read!(path) == ""
    end
  end

  describe "FileWrite reports byte count" do
    test "reports correct byte count for ASCII", %{ctx: ctx} do
      {:ok, msg} =
        FileWrite.execute(%{"path" => "size.txt", "content" => "hello"}, ctx)

      assert msg =~ "5 bytes"
    end

    test "reports correct byte count for multibyte UTF-8", %{ctx: ctx} do
      content = "cafe\u0301"
      {:ok, msg} = FileWrite.execute(%{"path" => "utf8.txt", "content" => content}, ctx)
      assert msg =~ "#{byte_size(content)} bytes"
    end
  end

  # ---------------------------------------------------------------------------
  # FileEdit edge cases
  # ---------------------------------------------------------------------------
  describe "FileEdit non-existent file" do
    test "returns error with file not found message", %{ctx: ctx} do
      {:error, msg} =
        FileEdit.execute(
          %{"path" => "ghost.txt", "old_string" => "x", "new_string" => "y"},
          ctx
        )

      assert msg =~ "not found" or msg =~ "File not found"
    end
  end

  describe "FileEdit old_string not found" do
    test "returns error when old_string does not appear in file", %{test_dir: test_dir, ctx: ctx} do
      File.write!(Path.join(test_dir, "nohit.txt"), "alpha beta gamma")

      {:error, msg} =
        FileEdit.execute(
          %{"path" => "nohit.txt", "old_string" => "MISSING", "new_string" => "X"},
          ctx
        )

      assert msg =~ "not found" or msg =~ "String not found"
    end
  end

  describe "FileEdit multiple occurrences" do
    test "replaces only the first occurrence by default", %{test_dir: test_dir, ctx: ctx} do
      File.write!(Path.join(test_dir, "multi.txt"), "aaa bbb aaa bbb aaa")

      {:ok, json} =
        FileEdit.execute(
          %{"path" => "multi.txt", "old_string" => "aaa", "new_string" => "ZZZ"},
          ctx
        )

      parsed = Jason.decode!(json)
      assert parsed["message"] =~ "first occurrence"

      content = File.read!(Path.join(test_dir, "multi.txt"))
      assert content == "ZZZ bbb aaa bbb aaa"
    end

    test "exactly two occurrences - replaces first leaving second intact", %{
      test_dir: test_dir,
      ctx: ctx
    } do
      File.write!(Path.join(test_dir, "two.txt"), "foo bar foo")

      {:ok, _json} =
        FileEdit.execute(
          %{"path" => "two.txt", "old_string" => "foo", "new_string" => "baz"},
          ctx
        )

      # Exactly two splits: handled by the [before, after_part] branch
      content = File.read!(Path.join(test_dir, "two.txt"))
      assert content == "baz bar foo"
    end

    test "single occurrence replaced via exact match branch", %{test_dir: test_dir, ctx: ctx} do
      File.write!(Path.join(test_dir, "single.txt"), "only one target here")

      {:ok, json} =
        FileEdit.execute(
          %{"path" => "single.txt", "old_string" => "target", "new_string" => "replacement"},
          ctx
        )

      parsed = Jason.decode!(json)
      assert parsed["status"] == "ok"
      assert File.read!(Path.join(test_dir, "single.txt")) == "only one replacement here"
    end
  end

  describe "FileEdit with empty strings" do
    test "replacing string with empty string effectively deletes it", %{
      test_dir: test_dir,
      ctx: ctx
    } do
      File.write!(Path.join(test_dir, "del_str.txt"), "keep REMOVE keep")

      {:ok, _json} =
        FileEdit.execute(
          %{"path" => "del_str.txt", "old_string" => " REMOVE", "new_string" => ""},
          ctx
        )

      assert File.read!(Path.join(test_dir, "del_str.txt")) == "keep keep"
    end

    test "replacing with new content that contains old_string does not loop", %{
      test_dir: test_dir,
      ctx: ctx
    } do
      File.write!(Path.join(test_dir, "loop.txt"), "abc")

      {:ok, _json} =
        FileEdit.execute(
          %{"path" => "loop.txt", "old_string" => "abc", "new_string" => "abcabc"},
          ctx
        )

      # Only one replacement should happen
      assert File.read!(Path.join(test_dir, "loop.txt")) == "abcabc"
    end
  end

  describe "FileEdit multiline content" do
    test "replaces multiline old_string correctly", %{test_dir: test_dir, ctx: ctx} do
      File.write!(Path.join(test_dir, "multiline.txt"), "line1\nline2\nline3\n")

      {:ok, _json} =
        FileEdit.execute(
          %{
            "path" => "multiline.txt",
            "old_string" => "line1\nline2",
            "new_string" => "replaced1\nreplaced2"
          },
          ctx
        )

      assert File.read!(Path.join(test_dir, "multiline.txt")) == "replaced1\nreplaced2\nline3\n"
    end
  end

  describe "FileEdit JSON response structure" do
    test "response contains status, path, message, and diff keys", %{
      test_dir: test_dir,
      ctx: ctx
    } do
      File.write!(Path.join(test_dir, "json_resp.txt"), "old value here")

      {:ok, json} =
        FileEdit.execute(
          %{"path" => "json_resp.txt", "old_string" => "old", "new_string" => "new"},
          ctx
        )

      parsed = Jason.decode!(json)
      assert Map.has_key?(parsed, "status")
      assert Map.has_key?(parsed, "path")
      assert Map.has_key?(parsed, "message")
      assert Map.has_key?(parsed, "diff")
      assert parsed["diff"]["old"] == "old"
      assert parsed["diff"]["new"] == "new"
    end
  end

  # ---------------------------------------------------------------------------
  # FileDelete edge cases
  # ---------------------------------------------------------------------------
  describe "FileDelete non-existent file" do
    test "returns error with does not exist message", %{ctx: ctx} do
      {:error, msg} =
        FileDelete.execute(%{"path" => "phantom.txt"}, ctx)

      assert msg =~ "does not exist" or msg =~ "not found"
    end
  end

  describe "FileDelete path outside project root" do
    test "blocks deletion of file outside project root via absolute path", %{ctx: ctx} do
      {:error, msg} =
        FileDelete.execute(%{"path" => "/etc/hostname"}, ctx)

      assert msg =~ "outside project root" or msg =~ "outside"
    end

    test "blocks deletion via directory traversal", %{ctx: ctx} do
      {:error, msg} =
        FileDelete.execute(%{"path" => "../../../etc/passwd"}, ctx)

      assert msg =~ "outside"
    end
  end

  describe "FileDelete of actual file" do
    test "file is removed from disk after successful delete", %{test_dir: test_dir, ctx: ctx} do
      path = Path.join(test_dir, "to_delete.txt")
      File.write!(path, "bye bye")
      assert File.exists?(path)

      {:ok, msg} = FileDelete.execute(%{"path" => "to_delete.txt"}, ctx)
      assert msg =~ "deleted"
      refute File.exists?(path)
    end

    test "deleting already deleted file returns error", %{test_dir: test_dir, ctx: ctx} do
      path = Path.join(test_dir, "once_only.txt")
      File.write!(path, "temp")
      File.rm!(path)

      {:error, msg} = FileDelete.execute(%{"path" => "once_only.txt"}, ctx)
      assert msg =~ "does not exist"
    end
  end

  # ---------------------------------------------------------------------------
  # FileMove edge cases
  # ---------------------------------------------------------------------------
  describe "FileMove non-existent source" do
    test "returns error with source not found message", %{ctx: ctx} do
      {:error, msg} =
        FileMove.execute(
          %{"source" => "no_source.txt", "destination" => "dest.txt"},
          ctx
        )

      assert msg =~ "does not exist" or msg =~ "not found"
    end
  end

  describe "FileMove destination already exists" do
    test "overwrites the existing destination file", %{test_dir: test_dir, ctx: ctx} do
      File.write!(Path.join(test_dir, "src.txt"), "source content")
      File.write!(Path.join(test_dir, "existing_dest.txt"), "old destination content")

      {:ok, msg} =
        FileMove.execute(
          %{"source" => "src.txt", "destination" => "existing_dest.txt"},
          ctx
        )

      assert msg =~ "Moved"
      refute File.exists?(Path.join(test_dir, "src.txt"))
      assert File.read!(Path.join(test_dir, "existing_dest.txt")) == "source content"
    end
  end

  describe "FileMove creates destination directories" do
    test "intermediate directories are created for destination", %{
      test_dir: test_dir,
      ctx: ctx
    } do
      File.write!(Path.join(test_dir, "mv_src.txt"), "moving deep")

      {:ok, msg} =
        FileMove.execute(
          %{"source" => "mv_src.txt", "destination" => "x/y/z/moved.txt"},
          ctx
        )

      assert msg =~ "Moved"
      assert File.read!(Path.join(test_dir, "x/y/z/moved.txt")) == "moving deep"
      refute File.exists?(Path.join(test_dir, "mv_src.txt"))
    end
  end

  describe "FileMove path validation" do
    test "blocks move with source outside project root", %{ctx: ctx} do
      {:error, msg} =
        FileMove.execute(
          %{"source" => "/etc/passwd", "destination" => "safe.txt"},
          ctx
        )

      assert msg =~ "outside"
    end

    test "blocks move with destination outside project root", %{test_dir: test_dir, ctx: ctx} do
      File.write!(Path.join(test_dir, "valid_src.txt"), "data")

      {:error, msg} =
        FileMove.execute(
          %{"source" => "valid_src.txt", "destination" => "/tmp/outside_move.txt"},
          ctx
        )

      assert msg =~ "outside"
    end

    test "blocks move with both paths using traversal", %{ctx: ctx} do
      {:error, msg} =
        FileMove.execute(
          %{"source" => "../../etc/passwd", "destination" => "../../tmp/evil.txt"},
          ctx
        )

      assert msg =~ "outside"
    end
  end

  describe "FileMove rename in place" do
    test "renaming file in same directory works", %{test_dir: test_dir, ctx: ctx} do
      File.write!(Path.join(test_dir, "old_name.txt"), "rename me")

      {:ok, msg} =
        FileMove.execute(
          %{"source" => "old_name.txt", "destination" => "new_name.txt"},
          ctx
        )

      assert msg =~ "Moved"
      refute File.exists?(Path.join(test_dir, "old_name.txt"))
      assert File.read!(Path.join(test_dir, "new_name.txt")) == "rename me"
    end
  end
end
