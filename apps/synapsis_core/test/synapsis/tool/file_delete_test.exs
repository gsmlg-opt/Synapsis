defmodule Synapsis.Tool.FileDeleteTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.FileDelete

  @tag :tmp_dir
  test "deletes existing file", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "doomed.txt")
    File.write!(path, "goodbye")

    {:ok, msg} = FileDelete.execute(%{"path" => path}, %{project_path: tmp_dir})
    assert msg =~ "Successfully deleted"
    refute File.exists?(path)
  end

  @tag :tmp_dir
  test "returns error for missing file", %{tmp_dir: tmp_dir} do
    {:error, msg} =
      FileDelete.execute(%{"path" => Path.join(tmp_dir, "ghost.txt")}, %{project_path: tmp_dir})

    assert msg =~ "does not exist"
  end

  @tag :tmp_dir
  test "rejects path outside project root", %{tmp_dir: tmp_dir} do
    {:error, _} = FileDelete.execute(%{"path" => "/tmp/nope.txt"}, %{project_path: tmp_dir})
  end

  test "declares destructive permission and file_changed side effect" do
    assert FileDelete.permission_level() == :destructive
    assert :file_changed in FileDelete.side_effects()
    assert FileDelete.category() == :filesystem
  end
end
