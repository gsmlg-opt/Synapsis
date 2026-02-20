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

    test "non-map base is replaced by override" do
      assert Config.deep_merge("old_value", %{"a" => 1}) == %{"a" => 1}
      assert Config.deep_merge(42, "new") == "new"
    end
  end

  describe "load_project_config/1" do
    test "returns empty map for nil path" do
      assert Config.load_project_config(nil) == %{}
    end

    test "returns empty map for non-existent path" do
      assert Config.load_project_config("/tmp/nonexistent_path_abc123") == %{}
    end

    test "returns parsed config when .opencode.json exists" do
      dir = "/tmp/config_test_#{:rand.uniform(100_000)}"
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, ".opencode.json"), ~s({"model": "claude-3"}))

      config = Config.load_project_config(dir)
      assert config["model"] == "claude-3"

      File.rm_rf!(dir)
    end
  end

  describe "resolve/1" do
    test "returns defaults when no config files exist" do
      config = Config.resolve("/tmp/nonexistent_project_path_#{:rand.uniform(100_000)}")
      assert is_map(config["agents"])
      assert is_map(config["providers"])
    end

    test "project config overrides defaults" do
      dir = "/tmp/config_resolve_test_#{:rand.uniform(100_000)}"
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, ".opencode.json"), ~s({"custom_key": "custom_value"}))

      config = Config.resolve(dir)
      assert config["custom_key"] == "custom_value"
      assert is_map(config["agents"])

      File.rm_rf!(dir)
    end
  end

  describe "load_user_config/0" do
    test "returns a map (empty when file absent)" do
      result = Config.load_user_config()
      assert is_map(result)
    end
  end

  describe "load_auth/0" do
    test "returns a map (empty when file absent)" do
      result = Config.load_auth()
      assert is_map(result)
    end
  end

  describe "load_env_overrides/0" do
    test "picks up ANTHROPIC_API_KEY from env" do
      System.put_env("ANTHROPIC_API_KEY", "test-key-123")
      overrides = Config.load_env_overrides()
      assert get_in(overrides, ["providers", "anthropic", "apiKey"]) == "test-key-123"
      System.delete_env("ANTHROPIC_API_KEY")
    end

    test "picks up OPENAI_API_KEY from env" do
      System.put_env("OPENAI_API_KEY", "sk-openai-test")
      overrides = Config.load_env_overrides()
      assert get_in(overrides, ["providers", "openai", "apiKey"]) == "sk-openai-test"
      System.delete_env("OPENAI_API_KEY")
    end

    test "picks up GOOGLE_API_KEY from env" do
      System.put_env("GOOGLE_API_KEY", "google-test-key")
      overrides = Config.load_env_overrides()
      assert get_in(overrides, ["providers", "google", "apiKey"]) == "google-test-key"
      System.delete_env("GOOGLE_API_KEY")
    end

    test "returns empty map when no env vars set" do
      System.delete_env("ANTHROPIC_API_KEY")
      System.delete_env("OPENAI_API_KEY")
      System.delete_env("GOOGLE_API_KEY")
      assert Config.load_env_overrides() == %{}
    end
  end
end
