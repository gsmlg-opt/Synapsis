defmodule Synapsis.Tool.FileReadTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.FileRead

  @tag :tmp_dir
  test "reads entire file", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "test.txt")
    File.write!(path, "line 1\nline 2\nline 3\n")

    {:ok, content} = FileRead.execute(%{"path" => path}, %{project_path: tmp_dir})
    assert content =~ "line 1"
    assert content =~ "line 3"
  end

  @tag :tmp_dir
  test "reads with offset and limit", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "test.txt")
    lines = Enum.map_join(1..20, "\n", &"line #{&1}")
    File.write!(path, lines)

    {:ok, content} =
      FileRead.execute(
        %{"path" => path, "offset" => 5, "limit" => 3},
        %{project_path: tmp_dir}
      )

    assert content =~ "line 6"
    refute content =~ "line 1"
  end

  @tag :tmp_dir
  test "returns error for missing file", %{tmp_dir: tmp_dir} do
    {:error, msg} =
      FileRead.execute(%{"path" => Path.join(tmp_dir, "missing.txt")}, %{project_path: tmp_dir})

    assert msg =~ "not found" or msg =~ "Not found"
  end

  @tag :tmp_dir
  test "rejects path outside project root", %{tmp_dir: tmp_dir} do
    {:error, msg} = FileRead.execute(%{"path" => "/etc/passwd"}, %{project_path: tmp_dir})
    assert msg =~ "outside project root"
  end

  @tag :tmp_dir
  test "reads empty file", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "empty.txt")
    File.write!(path, "")

    {:ok, content} = FileRead.execute(%{"path" => path}, %{project_path: tmp_dir})
    assert content == ""
  end

  test "returns correct metadata" do
    assert FileRead.name() == "file_read"
    assert FileRead.permission_level() == :read
    assert FileRead.category() == :filesystem
    assert is_binary(FileRead.description())
    assert is_map(FileRead.parameters())
  end
end
