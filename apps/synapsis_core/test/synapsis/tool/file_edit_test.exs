defmodule Synapsis.Tool.FileEditTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.FileEdit

  @tag :tmp_dir
  test "replaces exact match", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "edit.txt")
    File.write!(path, "hello world")

    {:ok, json} =
      FileEdit.execute(
        %{"path" => path, "old_string" => "hello", "new_string" => "goodbye"},
        %{project_path: tmp_dir}
      )

    assert File.read!(path) == "goodbye world"
    assert json =~ "ok"
  end

  @tag :tmp_dir
  test "fails when old_string not found", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "edit.txt")
    File.write!(path, "hello world")

    {:error, msg} =
      FileEdit.execute(
        %{"path" => path, "old_string" => "missing", "new_string" => "replacement"},
        %{project_path: tmp_dir}
      )

    assert msg =~ "not found"
    assert File.read!(path) == "hello world"
  end

  @tag :tmp_dir
  test "fails when file does not exist", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "nonexistent.txt")

    {:error, msg} =
      FileEdit.execute(
        %{"path" => path, "old_string" => "a", "new_string" => "b"},
        %{project_path: tmp_dir}
      )

    assert msg =~ "not found"
  end

  @tag :tmp_dir
  test "handles multiline replacements", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "multi.txt")
    File.write!(path, "line 1\nline 2\nline 3\n")

    {:ok, _} =
      FileEdit.execute(
        %{"path" => path, "old_string" => "line 2\nline 3", "new_string" => "replaced"},
        %{project_path: tmp_dir}
      )

    assert File.read!(path) == "line 1\nreplaced\n"
  end

  @tag :tmp_dir
  test "handles multiple occurrences by replacing first", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "dupes.txt")
    File.write!(path, "foo bar foo baz foo")

    {:ok, json} =
      FileEdit.execute(
        %{"path" => path, "old_string" => "foo", "new_string" => "qux"},
        %{project_path: tmp_dir}
      )

    assert File.read!(path) == "qux bar foo baz foo"
    assert json =~ "first occurrence"
  end

  @tag :tmp_dir
  test "rejects path outside project root", %{tmp_dir: tmp_dir} do
    {:error, msg} =
      FileEdit.execute(
        %{"path" => "/etc/passwd", "old_string" => "root", "new_string" => "evil"},
        %{project_path: tmp_dir}
      )

    assert msg =~ "outside project root"
  end

  test "declares write permission and file_changed side effect" do
    assert FileEdit.permission_level() == :write
    assert :file_changed in FileEdit.side_effects()
    assert FileEdit.category() == :filesystem
  end
end
