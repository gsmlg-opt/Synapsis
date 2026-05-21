defmodule Synapsis.ConfigTest do
  use ExUnit.Case, async: false

  alias Synapsis.Config

  @provider_env_vars ~w(
    ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_MODEL
    ANTHROPIC_DEFAULT_SONNET_MODEL OPENAI_API_KEY OPENAI_BASE_URL OPENAI_MODEL
    GOOGLE_API_KEY GOOGLE_BASE_URL GOOGLE_MODEL OPENROUTER_API_KEY
    OPENROUTER_BASE_URL OPENROUTER_MODEL
  )

  describe "defaults/0" do
    test "returns expected default config structure" do
      config = Config.defaults()
      assert is_map(config["agents"])
      assert is_map(config["agents"]["main"])
      assert Map.keys(config["agents"]) == ["main"]
      assert "file_read" in config["agents"]["main"]["tools"]
      assert "bash" in config["agents"]["main"]["tools"]
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

    test "deeply nested three-level merge" do
      base = %{"a" => %{"b" => %{"c" => 1, "d" => 2}}}
      override = %{"a" => %{"b" => %{"c" => 10, "e" => 3}}}
      result = Config.deep_merge(base, override)
      assert result == %{"a" => %{"b" => %{"c" => 10, "d" => 2, "e" => 3}}}
    end

    test "override replaces list values entirely (no list merge)" do
      base = %{"tools" => ["a", "b"]}
      override = %{"tools" => ["c"]}
      assert Config.deep_merge(base, override) == %{"tools" => ["c"]}
    end

    test "nil override replaces map" do
      assert Config.deep_merge(%{"a" => %{"b" => 1}}, nil) == nil
    end
  end

  describe "defaults/0 structure" do
    test "main agent has fetch tool" do
      config = Config.defaults()
      assert "fetch" in config["agents"]["main"]["tools"]
    end

    test "main agent is write-enabled with medium reasoning effort" do
      config = Config.defaults()
      assert config["agents"]["main"]["readOnly"] == false
      assert config["agents"]["main"]["reasoningEffort"] == "medium"
    end

    test "top-level keys exist" do
      config = Config.defaults()
      assert Map.has_key?(config, "agents")
      assert Map.has_key?(config, "providers")
      assert Map.has_key?(config, "mcpServers")
      assert Map.has_key?(config, "lsp")
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

    test "returns empty map for invalid JSON content" do
      dir = "/tmp/config_test_invalid_#{:rand.uniform(100_000)}"
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, ".opencode.json"), "not valid json {{")

      assert Config.load_project_config(dir) == %{}

      File.rm_rf!(dir)
    end

    test "returns empty map when JSON is not a map (e.g. array)" do
      dir = "/tmp/config_test_arr_#{:rand.uniform(100_000)}"
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, ".opencode.json"), "[1, 2, 3]")

      assert Config.load_project_config(dir) == %{}

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
      preserve_provider_env()
      System.put_env("ANTHROPIC_API_KEY", "test-key-123")
      overrides = Config.load_env_overrides()
      assert get_in(overrides, ["providers", "anthropic", "apiKey"]) == "test-key-123"
    end

    test "picks up Anthropic-compatible auth, base URL, and model env aliases" do
      preserve_provider_env()
      System.delete_env("ANTHROPIC_API_KEY")
      System.put_env("ANTHROPIC_AUTH_TOKEN", "test-auth-token")
      System.put_env("ANTHROPIC_BASE_URL", "https://example.test/anthropic")
      System.put_env("ANTHROPIC_MODEL", "example-model")

      overrides = Config.load_env_overrides()
      assert get_in(overrides, ["providers", "anthropic", "apiKey"]) == "test-auth-token"

      assert get_in(overrides, ["providers", "anthropic", "baseURL"]) ==
               "https://example.test/anthropic"

      assert get_in(overrides, ["providers", "anthropic", "model"]) == "example-model"
    end

    test "picks up OPENAI_API_KEY from env" do
      preserve_provider_env()
      System.put_env("OPENAI_API_KEY", "sk-openai-test")
      overrides = Config.load_env_overrides()
      assert get_in(overrides, ["providers", "openai", "apiKey"]) == "sk-openai-test"
    end

    test "picks up GOOGLE_API_KEY from env" do
      preserve_provider_env()
      System.put_env("GOOGLE_API_KEY", "google-test-key")
      overrides = Config.load_env_overrides()
      assert get_in(overrides, ["providers", "google", "apiKey"]) == "google-test-key"
    end

    test "returns empty map when no env vars set" do
      preserve_provider_env()
      Enum.each(@provider_env_vars, &System.delete_env/1)
      assert Config.load_env_overrides() == %{}
    end
  end

  defp preserve_provider_env do
    previous = Map.new(@provider_env_vars, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)
    end)
  end
end
