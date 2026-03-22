defmodule Synapsis.Tool.FileWriteTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.FileWrite

  @tag :tmp_dir
  test "creates new file", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "new.txt")

    {:ok, msg} =
      FileWrite.execute(%{"path" => path, "content" => "hello"}, %{project_path: tmp_dir})

    assert msg =~ "Successfully wrote"
    assert File.read!(path) == "hello"
  end

  @tag :tmp_dir
  test "creates parent directories", %{tmp_dir: tmp_dir} do
    path = Path.join([tmp_dir, "nested", "deep", "file.txt"])

    {:ok, _} =
      FileWrite.execute(%{"path" => path, "content" => "nested"}, %{project_path: tmp_dir})

    assert File.read!(path) == "nested"
  end

  @tag :tmp_dir
  test "overwrites existing file", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "existing.txt")
    File.write!(path, "old content")

    {:ok, _} =
      FileWrite.execute(%{"path" => path, "content" => "new content"}, %{project_path: tmp_dir})

    assert File.read!(path) == "new content"
  end

  @tag :tmp_dir
  test "rejects path outside project root", %{tmp_dir: tmp_dir} do
    {:error, _} =
      FileWrite.execute(%{"path" => "/tmp/evil.txt", "content" => "bad"}, %{project_path: tmp_dir})
  end

  test "declares write permission and file_changed side effect" do
    assert FileWrite.permission_level() == :write
    assert :file_changed in FileWrite.side_effects()
    assert FileWrite.category() == :filesystem
  end
end
