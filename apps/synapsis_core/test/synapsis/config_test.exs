defmodule Synapsis.ConfigTest do
  use ExUnit.Case, async: true

  alias Synapsis.Config

  describe "defaults/0" do
    test "returns expected default config structure" do
      config = Config.defaults()
      assert is_map(config["agents"])
      assert is_map(config["agents"]["build"])
      assert is_map(config["agents"]["plan"])
      assert config["agents"]["plan"]["readOnly"] == true
      assert "file_read" in config["agents"]["build"]["tools"]
      assert "bash" in config["agents"]["build"]["tools"]
    end
  end

  describe "deep_merge/2" do
    test "merges nested maps" do
      base = %{"a" => %{"b" => 1, "c" => 2}, "d" => 3}
      override = %{"a" => %{"b" => 10, "e" => 5}}
      result = Config.deep_merge(base, override)
      assert result == %{"a" => %{"b" => 10, "c" => 2, "e" => 5}, "d" => 3}
    end

    test "override replaces non-map values" do
      base = %{"a" => 1}
      override = %{"a" => 2}
      assert Config.deep_merge(base, override) == %{"a" => 2}
    end

    test "handles empty override" do
      base = %{"a" => 1}
      assert Config.deep_merge(base, %{}) == %{"a" => 1}
    end
  end

  describe "resolve/1" do
    test "returns defaults when no config files exist" do
      config = Config.resolve("/tmp/nonexistent_project_path_#{:rand.uniform(100_000)}")
      assert is_map(config["agents"])
      assert is_map(config["providers"])
    end
  end

  describe "load_env_overrides/0" do
    test "picks up ANTHROPIC_API_KEY from env" do
      System.put_env("ANTHROPIC_API_KEY", "test-key-123")
      overrides = Config.load_env_overrides()
      assert get_in(overrides, ["providers", "anthropic", "apiKey"]) == "test-key-123"
      System.delete_env("ANTHROPIC_API_KEY")
    end
  end
end
