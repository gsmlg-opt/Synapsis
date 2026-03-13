defmodule SynapsisPlugin.LSP.PresetsTest do
  use ExUnit.Case, async: true

  alias SynapsisPlugin.LSP.Presets

  setup do
    tmp =
      System.tmp_dir!()
      |> Path.join("lsp_presets_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, dir: tmp}
  end

  describe "all/0" do
    test "returns 13 presets" do
      assert length(Presets.all()) == 13
    end

    test "each preset has required keys" do
      for preset <- Presets.all() do
        assert Map.has_key?(preset, :name)
        assert Map.has_key?(preset, :description)
        assert Map.has_key?(preset, :command)
        assert Map.has_key?(preset, :args)
        assert Map.has_key?(preset, :extensions)
        assert Map.has_key?(preset, :markers)
        assert Map.has_key?(preset, :extension_to_language)
      end
    end

    test "includes all expected languages" do
      names = Enum.map(Presets.all(), & &1.name)
      assert "elixir-ls" in names
      assert "typescript" in names
      assert "gopls" in names
      assert "pyright" in names
      assert "rust-analyzer" in names
      assert "clangd" in names
      assert "intelephense" in names
      assert "sourcekit-lsp" in names
      assert "kotlin-lsp" in names
      assert "csharp-ls" in names
      assert "jdtls" in names
      assert "lua-language-server" in names
      assert "ruby-lsp" in names
    end
  end

  describe "get/1" do
    test "returns preset for elixir-ls" do
      preset = Presets.get("elixir-ls")
      assert preset.name == "elixir-ls"
      assert preset.command == "elixir-ls"
    end

    test "returns preset for typescript" do
      preset = Presets.get("typescript")
      assert preset.name == "typescript"
      assert preset.command == "typescript-language-server"
    end

    test "returns preset for gopls" do
      preset = Presets.get("gopls")
      assert preset.name == "gopls"
      assert preset.command == "gopls"
    end

    test "returns preset for pyright" do
      preset = Presets.get("pyright")
      assert preset.name == "pyright"
      assert preset.command == "pyright-langserver"
    end

    test "returns preset for rust-analyzer" do
      preset = Presets.get("rust-analyzer")
      assert preset.name == "rust-analyzer"
      assert preset.command == "rust-analyzer"
    end

    test "returns preset for clangd" do
      preset = Presets.get("clangd")
      assert preset.name == "clangd"
      assert preset.command == "clangd"
    end

    test "returns nil for unknown language" do
      assert Presets.get("unknown") == nil
    end
  end

  describe "builtin?/1" do
    test "returns true for built-in names" do
      assert Presets.builtin?("typescript")
      assert Presets.builtin?("gopls")
      assert Presets.builtin?("elixir-ls")
    end

    test "returns false for non-built-in names" do
      refute Presets.builtin?("my-custom-lsp")
      refute Presets.builtin?("unknown")
    end
  end

  describe "lsp_command/1" do
    test "returns {cmd, args} for known languages" do
      assert Presets.lsp_command("elixir-ls") == {"elixir-ls", ["--stdio"]}
      assert Presets.lsp_command("typescript") == {"typescript-language-server", ["--stdio"]}
      assert Presets.lsp_command("gopls") == {"gopls", []}
      assert Presets.lsp_command("pyright") == {"pyright-langserver", ["--stdio"]}
      assert Presets.lsp_command("rust-analyzer") == {"rust-analyzer", []}
      assert Presets.lsp_command("clangd") == {"clangd", ["--background-index"]}
    end

    test "returns nil for unknown language" do
      assert Presets.lsp_command("unknown") == nil
    end
  end

  describe "detect_languages/1" do
    test "returns empty list for empty directory", %{dir: dir} do
      assert Presets.detect_languages(dir) == []
    end

    test "detects elixir-ls from .ex files", %{dir: dir} do
      File.write!(Path.join(dir, "module.ex"), "defmodule Foo do\nend")
      assert "elixir-ls" in Presets.detect_languages(dir)
    end

    test "detects elixir-ls from .exs files", %{dir: dir} do
      File.write!(Path.join(dir, "script.exs"), "IO.puts \"hello\"")
      assert "elixir-ls" in Presets.detect_languages(dir)
    end

    test "detects elixir-ls from mix.exs marker", %{dir: dir} do
      File.write!(Path.join(dir, "mix.exs"), "")
      assert "elixir-ls" in Presets.detect_languages(dir)
    end

    test "detects typescript from .ts files", %{dir: dir} do
      File.write!(Path.join(dir, "app.ts"), "const x: number = 1;")
      assert "typescript" in Presets.detect_languages(dir)
    end

    test "detects typescript from package.json marker", %{dir: dir} do
      File.write!(Path.join(dir, "package.json"), "{}")
      assert "typescript" in Presets.detect_languages(dir)
    end

    test "detects gopls from .go files", %{dir: dir} do
      File.write!(Path.join(dir, "main.go"), "package main")
      assert "gopls" in Presets.detect_languages(dir)
    end

    test "detects pyright from .py files", %{dir: dir} do
      File.write!(Path.join(dir, "main.py"), "print('hello')")
      assert "pyright" in Presets.detect_languages(dir)
    end

    test "detects pyright from pyproject.toml marker", %{dir: dir} do
      File.write!(Path.join(dir, "pyproject.toml"), "")
      assert "pyright" in Presets.detect_languages(dir)
    end

    test "detects rust-analyzer from .rs files", %{dir: dir} do
      File.write!(Path.join(dir, "main.rs"), "fn main() {}")
      assert "rust-analyzer" in Presets.detect_languages(dir)
    end

    test "detects rust-analyzer from Cargo.toml marker", %{dir: dir} do
      File.write!(Path.join(dir, "Cargo.toml"), "")
      assert "rust-analyzer" in Presets.detect_languages(dir)
    end

    test "detects clangd from .c files", %{dir: dir} do
      File.write!(Path.join(dir, "main.c"), "int main() { return 0; }")
      assert "clangd" in Presets.detect_languages(dir)
    end

    test "detects clangd from .cpp files", %{dir: dir} do
      File.write!(Path.join(dir, "main.cpp"), "int main() { return 0; }")
      assert "clangd" in Presets.detect_languages(dir)
    end

    test "detects clangd from CMakeLists.txt marker", %{dir: dir} do
      File.write!(Path.join(dir, "CMakeLists.txt"), "")
      assert "clangd" in Presets.detect_languages(dir)
    end

    test "detects clangd from Makefile marker", %{dir: dir} do
      File.write!(Path.join(dir, "Makefile"), "")
      assert "clangd" in Presets.detect_languages(dir)
    end

    test "detects multiple languages", %{dir: dir} do
      File.write!(Path.join(dir, "module.ex"), "defmodule Foo do\nend")
      File.write!(Path.join(dir, "main.go"), "package main")
      File.write!(Path.join(dir, "main.py"), "print('hello')")

      langs = Presets.detect_languages(dir)
      assert "elixir-ls" in langs
      assert "gopls" in langs
      assert "pyright" in langs
    end

    test "does not detect non-present languages", %{dir: dir} do
      File.write!(Path.join(dir, "module.ex"), "defmodule Foo do\nend")
      langs = Presets.detect_languages(dir)
      refute "gopls" in langs
      refute "typescript" in langs
      refute "pyright" in langs
      refute "rust-analyzer" in langs
      refute "clangd" in langs
    end
  end
end
