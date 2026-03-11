defmodule Synapsis.Tool.MultiEditTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.MultiEdit

  setup do
    test_dir =
      Path.join(System.tmp_dir!(), "synapsis_multi_edit_#{System.unique_integer([:positive])}")

    File.mkdir_p!(test_dir)

    on_exit(fn -> File.rm_rf!(test_dir) end)

    %{test_dir: test_dir, ctx: %{project_path: test_dir}}
  end

  describe "single file with multiple edits" do
    test "all edits succeed sequentially", %{test_dir: test_dir, ctx: ctx} do
      File.write!(Path.join(test_dir, "app.txt"), "hello world foo bar")

      {:ok, msg} =
        MultiEdit.execute(
          %{
            "edits" => [
              %{"path" => "app.txt", "old_string" => "hello", "new_string" => "hi"},
              %{"path" => "app.txt", "old_string" => "foo", "new_string" => "baz"}
            ]
          },
          ctx
        )

      assert msg =~ "Applied 2 edit(s)"
      assert File.read!(Path.join(test_dir, "app.txt")) == "hi world baz bar"
    end

    test "edits apply in order (second edit sees result of first)", %{
      test_dir: test_dir,
      ctx: ctx
    } do
      File.write!(Path.join(test_dir, "seq.txt"), "aaa bbb")

      {:ok, _msg} =
        MultiEdit.execute(
          %{
            "edits" => [
              %{"path" => "seq.txt", "old_string" => "aaa", "new_string" => "ccc"},
              %{"path" => "seq.txt", "old_string" => "ccc bbb", "new_string" => "done"}
            ]
          },
          ctx
        )

      assert File.read!(Path.join(test_dir, "seq.txt")) == "done"
    end
  end

  describe "cross-file edits" do
    test "edits across two files both succeed", %{test_dir: test_dir, ctx: ctx} do
      File.write!(Path.join(test_dir, "file_a.txt"), "alpha beta")
      File.write!(Path.join(test_dir, "file_b.txt"), "gamma delta")

      {:ok, msg} =
        MultiEdit.execute(
          %{
            "edits" => [
              %{"path" => "file_a.txt", "old_string" => "alpha", "new_string" => "ALPHA"},
              %{"path" => "file_b.txt", "old_string" => "gamma", "new_string" => "GAMMA"}
            ]
          },
          ctx
        )

      assert msg =~ "Applied 1 edit(s) to"
      assert File.read!(Path.join(test_dir, "file_a.txt")) == "ALPHA beta"
      assert File.read!(Path.join(test_dir, "file_b.txt")) == "GAMMA delta"
    end
  end

  describe "partial success with rollback" do
    test "one file succeeds while another fails, reports partial success", %{
      test_dir: test_dir,
      ctx: ctx
    } do
      File.write!(Path.join(test_dir, "good.txt"), "good content")
      File.write!(Path.join(test_dir, "bad.txt"), "bad content")

      {:ok, msg} =
        MultiEdit.execute(
          %{
            "edits" => [
              %{"path" => "good.txt", "old_string" => "good", "new_string" => "great"},
              %{
                "path" => "bad.txt",
                "old_string" => "NONEXISTENT",
                "new_string" => "whatever"
              }
            ]
          },
          ctx
        )

      assert msg =~ "Partial success"
      assert msg =~ "Applied 1 edit(s)"
      assert msg =~ "string not found"

      # Good file was modified
      assert File.read!(Path.join(test_dir, "good.txt")) == "great content"
      # Bad file was rolled back to original
      assert File.read!(Path.join(test_dir, "bad.txt")) == "bad content"
    end

    test "rollback on second edit failure within a file", %{test_dir: test_dir, ctx: ctx} do
      File.write!(Path.join(test_dir, "rollback.txt"), "first second third")

      {:error, msg} =
        MultiEdit.execute(
          %{
            "edits" => [
              %{
                "path" => "rollback.txt",
                "old_string" => "first",
                "new_string" => "1st"
              },
              %{
                "path" => "rollback.txt",
                "old_string" => "MISSING",
                "new_string" => "nope"
              }
            ]
          },
          ctx
        )

      assert msg =~ "Edit 2 failed"
      # File should be rolled back to original content
      assert File.read!(Path.join(test_dir, "rollback.txt")) == "first second third"
    end
  end

  describe "non-existent file" do
    test "returns error when file does not exist", %{ctx: ctx} do
      {:error, msg} =
        MultiEdit.execute(
          %{
            "edits" => [
              %{
                "path" => "nonexistent.txt",
                "old_string" => "x",
                "new_string" => "y"
              }
            ]
          },
          ctx
        )

      assert msg =~ "File not found"
    end
  end

  describe "path validation" do
    test "rejects path outside project root", %{ctx: ctx} do
      {:error, msg} =
        MultiEdit.execute(
          %{
            "edits" => [
              %{
                "path" => "/etc/passwd",
                "old_string" => "root",
                "new_string" => "hacked"
              }
            ]
          },
          ctx
        )

      assert msg =~ "outside project root"
    end

    test "rejects directory traversal", %{ctx: ctx} do
      {:error, msg} =
        MultiEdit.execute(
          %{
            "edits" => [
              %{
                "path" => "../../../etc/passwd",
                "old_string" => "root",
                "new_string" => "hacked"
              }
            ]
          },
          ctx
        )

      assert msg =~ "outside"
    end
  end

  describe "empty edits" do
    test "returns success message with no edits to apply", %{ctx: ctx} do
      {:ok, msg} = MultiEdit.execute(%{"edits" => []}, ctx)
      assert msg =~ "No edits to apply"
    end

    test "nil edits treated as empty", %{ctx: ctx} do
      {:ok, msg} = MultiEdit.execute(%{}, ctx)
      assert msg =~ "No edits to apply"
    end
  end

  describe "metadata callbacks" do
    test "name returns multi_edit" do
      assert MultiEdit.name() == "multi_edit"
    end

    test "permission_level is write" do
      assert MultiEdit.permission_level() == :write
    end

    test "category is filesystem" do
      assert MultiEdit.category() == :filesystem
    end

    test "side_effects includes file_changed" do
      assert :file_changed in MultiEdit.side_effects()
    end
  end
end
