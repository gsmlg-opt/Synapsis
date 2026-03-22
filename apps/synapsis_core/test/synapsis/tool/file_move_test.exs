defmodule Synapsis.Tool.FileMoveTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.FileMove

  @tag :tmp_dir
  test "moves file to new location", %{tmp_dir: tmp_dir} do
    src = Path.join(tmp_dir, "original.txt")
    dst = Path.join(tmp_dir, "moved.txt")
    File.write!(src, "content")

    {:ok, msg} =
      FileMove.execute(%{"source" => src, "destination" => dst}, %{project_path: tmp_dir})

    assert msg =~ "Moved"
    refute File.exists?(src)
    assert File.read!(dst) == "content"
  end

  @tag :tmp_dir
  test "creates destination parent directories", %{tmp_dir: tmp_dir} do
    src = Path.join(tmp_dir, "file.txt")
    dst = Path.join([tmp_dir, "nested", "dir", "file.txt"])
    File.write!(src, "data")

    {:ok, _} =
      FileMove.execute(%{"source" => src, "destination" => dst}, %{project_path: tmp_dir})

    assert File.read!(dst) == "data"
  end

  @tag :tmp_dir
  test "returns error when source does not exist", %{tmp_dir: tmp_dir} do
    {:error, msg} =
      FileMove.execute(
        %{
          "source" => Path.join(tmp_dir, "nope.txt"),
          "destination" => Path.join(tmp_dir, "dest.txt")
        },
        %{project_path: tmp_dir}
      )

    assert msg =~ "does not exist"
  end

  @tag :tmp_dir
  test "rejects source path outside project root", %{tmp_dir: tmp_dir} do
    {:error, _} =
      FileMove.execute(
        %{"source" => "/etc/passwd", "destination" => Path.join(tmp_dir, "stolen.txt")},
        %{project_path: tmp_dir}
      )
  end

  test "declares write permission and file_changed side effect" do
    assert FileMove.permission_level() == :write
    assert :file_changed in FileMove.side_effects()
    assert FileMove.category() == :filesystem
  end
end
