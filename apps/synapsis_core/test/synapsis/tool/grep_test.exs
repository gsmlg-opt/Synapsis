defmodule Synapsis.Tool.GrepTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.Grep

  @tag :tmp_dir
  test "finds pattern in files", %{tmp_dir: tmp_dir} do
    File.write!(
      Path.join(tmp_dir, "haystack.txt"),
      "needle in a haystack\nno match here\nneedle again"
    )

    {:ok, content} =
      Grep.execute(
        %{"pattern" => "needle", "path" => tmp_dir},
        %{project_path: tmp_dir}
      )

    assert content =~ "needle"
  end

  @tag :tmp_dir
  test "returns no-matches message when pattern not found", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "file.txt"), "nothing relevant here")

    {:ok, content} =
      Grep.execute(
        %{"pattern" => "zzz_no_match_zzz", "path" => tmp_dir},
        %{project_path: tmp_dir}
      )

    assert content =~ "No matches"
  end

  @tag :tmp_dir
  test "filters by include glob", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "code.ex"), "defmodule Foo do\nend")
    File.write!(Path.join(tmp_dir, "readme.md"), "defmodule in docs")

    {:ok, content} =
      Grep.execute(
        %{"pattern" => "defmodule", "path" => tmp_dir, "include" => "*.ex"},
        %{project_path: tmp_dir}
      )

    assert content =~ "code.ex"
  end

  @tag :tmp_dir
  test "rejects path outside project root", %{tmp_dir: tmp_dir} do
    {:error, _} =
      Grep.execute(
        %{"pattern" => "root", "path" => "/etc"},
        %{project_path: tmp_dir}
      )
  end

  test "declares read permission and search category" do
    assert Grep.permission_level() == :read
    assert Grep.category() == :search
  end
end
