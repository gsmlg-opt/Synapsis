defmodule Synapsis.Tool.GlobTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.Glob

  @tag :tmp_dir
  test "finds files matching pattern", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "app.ex"), "")
    File.write!(Path.join(tmp_dir, "app.exs"), "")
    File.write!(Path.join(tmp_dir, "readme.md"), "")

    {:ok, content} =
      Glob.execute(
        %{"pattern" => "*.ex", "path" => tmp_dir},
        %{project_path: tmp_dir}
      )

    assert content =~ "app.ex"
  end

  @tag :tmp_dir
  test "returns message for no matches", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "file.txt"), "")

    {:ok, content} =
      Glob.execute(
        %{"pattern" => "*.rs", "path" => tmp_dir},
        %{project_path: tmp_dir}
      )

    assert content =~ "No files matched"
  end

  @tag :tmp_dir
  test "searches nested directories with wildcard", %{tmp_dir: tmp_dir} do
    nested = Path.join([tmp_dir, "a", "b"])
    File.mkdir_p!(nested)
    File.write!(Path.join(nested, "deep.ex"), "")

    {:ok, content} =
      Glob.execute(
        %{"pattern" => "**/*.ex", "path" => tmp_dir},
        %{project_path: tmp_dir}
      )

    assert content =~ "deep.ex"
  end

  test "declares read permission and search category" do
    assert Glob.permission_level() == :read
    assert Glob.category() == :search
  end
end
