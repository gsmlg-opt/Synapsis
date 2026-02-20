defmodule SynapsisPlugin.LSP.PositionTest do
  use ExUnit.Case, async: true

  alias SynapsisPlugin.LSP.Position

  setup do
    tmp = System.tmp_dir!() |> Path.join("lsp_position_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, dir: tmp}
  end

  describe "find_symbol/2" do
    test "finds symbol on first line", %{dir: dir} do
      path = Path.join(dir, "test.ex")
      File.write!(path, "defmodule MyModule do\n  def hello, do: :ok\nend")

      assert {:ok, %{line: 0, character: col}} = Position.find_symbol(path, "defmodule")
      assert col == 0
    end

    test "finds symbol on subsequent line", %{dir: dir} do
      path = Path.join(dir, "test.ex")
      File.write!(path, "defmodule MyModule do\n  def hello, do: :ok\nend")

      assert {:ok, %{line: 1, character: _}} = Position.find_symbol(path, "hello")
    end

    test "returns character position within line", %{dir: dir} do
      path = Path.join(dir, "test.ex")
      File.write!(path, "x = 1\ny = target_symbol + 1")

      assert {:ok, %{line: 1, character: 4}} = Position.find_symbol(path, "target_symbol")
    end

    test "returns not_found for missing symbol", %{dir: dir} do
      path = Path.join(dir, "test.ex")
      File.write!(path, "defmodule MyModule do\nend")

      assert {:error, :not_found} = Position.find_symbol(path, "nonexistent_symbol")
    end

    test "returns error for nonexistent file" do
      assert {:error, _} = Position.find_symbol("/nonexistent/file.ex", "hello")
    end
  end
end
