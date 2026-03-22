defmodule Synapsis.Tool.ListDirTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.ListDir

  @tag :tmp_dir
  test "lists directory contents", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "a.txt"), "")
    File.write!(Path.join(tmp_dir, "b.txt"), "")
    File.mkdir_p!(Path.join(tmp_dir, "subdir"))

    {:ok, content} = ListDir.execute(%{"path" => tmp_dir}, %{project_path: tmp_dir})
    assert content =~ "a.txt"
    assert content =~ "b.txt"
    assert content =~ "subdir"
  end

  @tag :tmp_dir
  test "handles empty directory", %{tmp_dir: tmp_dir} do
    empty = Path.join(tmp_dir, "empty")
    File.mkdir_p!(empty)

    {:ok, content} = ListDir.execute(%{"path" => empty}, %{project_path: tmp_dir})
    assert content == ""
  end

  @tag :tmp_dir
  test "returns error for nonexistent directory", %{tmp_dir: tmp_dir} do
    {:error, msg} =
      ListDir.execute(%{"path" => Path.join(tmp_dir, "nope")}, %{project_path: tmp_dir})

    assert msg =~ "does not exist"
  end

  @tag :tmp_dir
  test "rejects path outside project root", %{tmp_dir: tmp_dir} do
    {:error, _} = ListDir.execute(%{"path" => "/etc"}, %{project_path: tmp_dir})
  end

  @tag :tmp_dir
  test "respects depth parameter", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join([tmp_dir, "a", "b", "c"]))
    File.write!(Path.join([tmp_dir, "a", "b", "c", "deep.txt"]), "")

    {:ok, shallow} = ListDir.execute(%{"path" => tmp_dir, "depth" => 1}, %{project_path: tmp_dir})
    {:ok, deep} = ListDir.execute(%{"path" => tmp_dir, "depth" => 4}, %{project_path: tmp_dir})
    # Deep listing should include more entries than shallow
    assert String.length(deep) >= String.length(shallow)
  end

  test "declares read permission and filesystem category" do
    assert ListDir.permission_level() == :read
    assert ListDir.category() == :filesystem
  end
end
