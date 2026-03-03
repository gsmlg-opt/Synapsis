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
    test "returns 6 presets" do
      assert length(Presets.all()) == 6
    end

    test "each preset has required keys" do
      for preset <- Presets.all() do
        assert Map.has_key?(preset, :name)
        assert Map.has_key?(preset, :command)
        assert Map.has_key?(preset, :args)
        assert Map.has_key?(preset, :extensions)
        assert Map.has_key?(preset, :markers)
      end
    end

    test "includes all expected languages" do
      names = Enum.map(Presets.all(), & &1.name)
      assert "elixir" in names
      assert "typescript" in names
      assert "go" in names
      assert "python" in names
      assert "rust" in names
      assert "c_cpp" in names
    end
  end

  describe "get/1" do
    test "returns preset for elixir" do
      preset = Presets.get("elixir")
      assert preset.name == "elixir"
      assert preset.command == "elixir-ls"
    end

    test "returns preset for typescript" do
      preset = Presets.get("typescript")
      assert preset.name == "typescript"
      assert preset.command == "typescript-language-server"
    end

    test "returns preset for go" do
      preset = Presets.get("go")
      assert preset.name == "go"
      assert preset.command == "gopls"
    end

    test "returns preset for python" do
      preset = Presets.get("python")
      assert preset.name == "python"
      assert preset.command == "pyright-langserver"
    end

    test "returns preset for rust" do
      preset = Presets.get("rust")
      assert preset.name == "rust"
      assert preset.command == "rust-analyzer"
    end

    test "returns preset for c_cpp" do
      preset = Presets.get("c_cpp")
      assert preset.name == "c_cpp"
      assert preset.command == "clangd"
    end

    test "returns nil for unknown language" do
      assert Presets.get("unknown") == nil
      assert Presets.get("ruby") == nil
    end
  end

  describe "lsp_command/1" do
    test "returns {cmd, args} for known languages" do
      assert Presets.lsp_command("elixir") == {"elixir-ls", ["--stdio"]}
      assert Presets.lsp_command("typescript") == {"typescript-language-server", ["--stdio"]}
      assert Presets.lsp_command("go") == {"gopls", ["serve"]}
      assert Presets.lsp_command("python") == {"pyright-langserver", ["--stdio"]}
      assert Presets.lsp_command("rust") == {"rust-analyzer", []}
      assert Presets.lsp_command("c_cpp") == {"clangd", []}
    end

    test "returns nil for unknown language" do
      assert Presets.lsp_command("unknown") == nil
    end
  end

  describe "detect_languages/1" do
    test "returns empty list for empty directory", %{dir: dir} do
      assert Presets.detect_languages(dir) == []
    end

    test "detects elixir from .ex files", %{dir: dir} do
      File.write!(Path.join(dir, "module.ex"), "defmodule Foo do\nend")
      assert "elixir" in Presets.detect_languages(dir)
    end

    test "detects elixir from .exs files", %{dir: dir} do
      File.write!(Path.join(dir, "script.exs"), "IO.puts \"hello\"")
      assert "elixir" in Presets.detect_languages(dir)
    end

    test "detects elixir from mix.exs marker", %{dir: dir} do
      File.write!(Path.join(dir, "mix.exs"), "")
      assert "elixir" in Presets.detect_languages(dir)
    end

    test "detects typescript from .ts files", %{dir: dir} do
      File.write!(Path.join(dir, "app.ts"), "const x: number = 1;")
      assert "typescript" in Presets.detect_languages(dir)
    end

    test "detects typescript from package.json marker", %{dir: dir} do
      File.write!(Path.join(dir, "package.json"), "{}")
      assert "typescript" in Presets.detect_languages(dir)
    end

    test "detects go from .go files", %{dir: dir} do
      File.write!(Path.join(dir, "main.go"), "package main")
      assert "go" in Presets.detect_languages(dir)
    end

    test "detects python from .py files", %{dir: dir} do
      File.write!(Path.join(dir, "main.py"), "print('hello')")
      assert "python" in Presets.detect_languages(dir)
    end

    test "detects python from pyproject.toml marker", %{dir: dir} do
      File.write!(Path.join(dir, "pyproject.toml"), "")
      assert "python" in Presets.detect_languages(dir)
    end

    test "detects rust from .rs files", %{dir: dir} do
      File.write!(Path.join(dir, "main.rs"), "fn main() {}")
      assert "rust" in Presets.detect_languages(dir)
    end

    test "detects rust from Cargo.toml marker", %{dir: dir} do
      File.write!(Path.join(dir, "Cargo.toml"), "")
      assert "rust" in Presets.detect_languages(dir)
    end

    test "detects c_cpp from .c files", %{dir: dir} do
      File.write!(Path.join(dir, "main.c"), "int main() { return 0; }")
      assert "c_cpp" in Presets.detect_languages(dir)
    end

    test "detects c_cpp from .cpp files", %{dir: dir} do
      File.write!(Path.join(dir, "main.cpp"), "int main() { return 0; }")
      assert "c_cpp" in Presets.detect_languages(dir)
    end

    test "detects c_cpp from CMakeLists.txt marker", %{dir: dir} do
      File.write!(Path.join(dir, "CMakeLists.txt"), "")
      assert "c_cpp" in Presets.detect_languages(dir)
    end

    test "detects c_cpp from Makefile marker", %{dir: dir} do
      File.write!(Path.join(dir, "Makefile"), "")
      assert "c_cpp" in Presets.detect_languages(dir)
    end

    test "detects multiple languages", %{dir: dir} do
      File.write!(Path.join(dir, "module.ex"), "defmodule Foo do\nend")
      File.write!(Path.join(dir, "main.go"), "package main")
      File.write!(Path.join(dir, "main.py"), "print('hello')")

      langs = Presets.detect_languages(dir)
      assert "elixir" in langs
      assert "go" in langs
      assert "python" in langs
    end

    test "does not detect non-present languages", %{dir: dir} do
      File.write!(Path.join(dir, "module.ex"), "defmodule Foo do\nend")
      langs = Presets.detect_languages(dir)
      refute "go" in langs
      refute "typescript" in langs
      refute "python" in langs
      refute "rust" in langs
      refute "c_cpp" in langs
    end
  end
end
