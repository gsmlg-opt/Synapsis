defmodule Synapsis.LSP.ManagerTest do
  use ExUnit.Case

  alias Synapsis.LSP.Manager

  describe "detect_languages/1" do
    test "detects elixir from .ex files" do
      # This project itself has .ex files
      languages = Manager.detect_languages(Path.expand("../../..", __DIR__))
      assert "elixir" in languages
    end

    test "returns empty for nonexistent directory" do
      languages = Manager.detect_languages("/tmp/nonexistent_#{:rand.uniform(100_000)}")
      assert languages == []
    end
  end

  describe "get_all_diagnostics/1" do
    test "returns ok even with no servers running" do
      {:ok, diagnostics} =
        Manager.get_all_diagnostics("/tmp/no_servers_#{:rand.uniform(100_000)}")

      assert is_map(diagnostics)
    end
  end
end
