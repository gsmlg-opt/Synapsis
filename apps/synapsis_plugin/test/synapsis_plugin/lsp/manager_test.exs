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

    test "detects elixir-ls from .ex files", %{dir: dir} do
      File.write!(Path.join(dir, "module.ex"), "defmodule Foo do\nend")
      langs = Manager.detect_languages(dir)
      assert "elixir-ls" in langs
    end

    test "detects elixir-ls from .exs files", %{dir: dir} do
      File.write!(Path.join(dir, "script.exs"), "IO.puts \"hello\"")
      langs = Manager.detect_languages(dir)
      assert "elixir-ls" in langs
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

    test "detects gopls from .go files", %{dir: dir} do
      File.write!(Path.join(dir, "main.go"), "package main")
      langs = Manager.detect_languages(dir)
      assert "gopls" in langs
    end

    test "detects pyright from .py files", %{dir: dir} do
      File.write!(Path.join(dir, "main.py"), "print('hello')")
      langs = Manager.detect_languages(dir)
      assert "pyright" in langs
    end

    test "detects rust-analyzer from .rs files", %{dir: dir} do
      File.write!(Path.join(dir, "main.rs"), "fn main() {}")
      langs = Manager.detect_languages(dir)
      assert "rust-analyzer" in langs
    end

    test "detects clangd from .c files", %{dir: dir} do
      File.write!(Path.join(dir, "main.c"), "int main() { return 0; }")
      langs = Manager.detect_languages(dir)
      assert "clangd" in langs
    end

    test "detects clangd from .cpp files", %{dir: dir} do
      File.write!(Path.join(dir, "main.cpp"), "int main() { return 0; }")
      langs = Manager.detect_languages(dir)
      assert "clangd" in langs
    end

    test "detects multiple languages when files exist", %{dir: dir} do
      File.write!(Path.join(dir, "module.ex"), "defmodule Foo do\nend")
      File.write!(Path.join(dir, "main.go"), "package main")
      langs = Manager.detect_languages(dir)
      assert "elixir-ls" in langs
      assert "gopls" in langs
    end

    test "does not detect non-present languages", %{dir: dir} do
      File.write!(Path.join(dir, "module.ex"), "defmodule Foo do\nend")
      langs = Manager.detect_languages(dir)
      refute "gopls" in langs
      refute "typescript" in langs
      refute "pyright" in langs
      refute "rust-analyzer" in langs
      refute "clangd" in langs
    end
  end
end
