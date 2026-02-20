defmodule SynapsisPlugin.LSP.ManagerTest do
  use ExUnit.Case, async: true

  alias SynapsisPlugin.LSP.Manager

  setup do
    tmp =
      System.tmp_dir!()
      |> Path.join("lsp_manager_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, dir: tmp}
  end

  describe "detect_languages/1" do
    test "returns empty list for empty directory", %{dir: dir} do
      assert Manager.detect_languages(dir) == []
    end

    test "detects elixir from .ex files", %{dir: dir} do
      File.write!(Path.join(dir, "module.ex"), "defmodule Foo do\nend")
      langs = Manager.detect_languages(dir)
      assert "elixir" in langs
    end

    test "detects elixir from .exs files", %{dir: dir} do
      File.write!(Path.join(dir, "script.exs"), "IO.puts \"hello\"")
      langs = Manager.detect_languages(dir)
      assert "elixir" in langs
    end

    test "detects typescript from .ts files", %{dir: dir} do
      File.write!(Path.join(dir, "app.ts"), "const x: number = 1;")
      langs = Manager.detect_languages(dir)
      assert "typescript" in langs
    end

    test "detects typescript from .tsx files", %{dir: dir} do
      File.write!(Path.join(dir, "component.tsx"), "export default () => <div/>;")
      langs = Manager.detect_languages(dir)
      assert "typescript" in langs
    end

    test "detects go from .go files", %{dir: dir} do
      File.write!(Path.join(dir, "main.go"), "package main")
      langs = Manager.detect_languages(dir)
      assert "go" in langs
    end

    test "detects multiple languages when files exist", %{dir: dir} do
      File.write!(Path.join(dir, "module.ex"), "defmodule Foo do\nend")
      File.write!(Path.join(dir, "main.go"), "package main")
      langs = Manager.detect_languages(dir)
      assert "elixir" in langs
      assert "go" in langs
    end

    test "does not detect non-present languages", %{dir: dir} do
      File.write!(Path.join(dir, "module.ex"), "defmodule Foo do\nend")
      langs = Manager.detect_languages(dir)
      refute "go" in langs
      refute "typescript" in langs
    end
  end
end
