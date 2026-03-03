defmodule SynapsisPlugin.MCP.PresetsTest do
  use ExUnit.Case, async: true

  alias SynapsisPlugin.MCP.Presets

  describe "all/0" do
    test "returns 12 presets" do
      assert length(Presets.all()) == 12
    end

    test "each preset has required keys" do
      for preset <- Presets.all() do
        assert Map.has_key?(preset, :name)
        assert Map.has_key?(preset, :description)
        assert Map.has_key?(preset, :command)
        assert Map.has_key?(preset, :args)
        assert Map.has_key?(preset, :env)
        assert Map.has_key?(preset, :transport)
      end
    end

    test "includes expected servers" do
      names = Enum.map(Presets.all(), & &1.name)
      assert "filesystem" in names
      assert "github" in names
      assert "playwright" in names
      assert "memory" in names
      assert "brave-search" in names
      assert "fetch" in names
      assert "git" in names
      assert "sequential-thinking" in names
      assert "postgres" in names
      assert "sqlite" in names
      assert "puppeteer" in names
      assert "slack" in names
    end

    test "all presets use stdio transport" do
      for preset <- Presets.all() do
        assert preset.transport == "stdio"
      end
    end
  end

  describe "get/1" do
    test "returns preset for filesystem" do
      preset = Presets.get("filesystem")
      assert preset.name == "filesystem"
      assert preset.command == "npx"
      assert "-y" in preset.args
    end

    test "returns preset for github" do
      preset = Presets.get("github")
      assert preset.name == "github"
      assert preset.command == "npx"
      assert Map.has_key?(preset.env, "GITHUB_PERSONAL_ACCESS_TOKEN")
    end

    test "returns preset for playwright" do
      preset = Presets.get("playwright")
      assert preset.name == "playwright"
      assert preset.command == "npx"
    end

    test "returns preset for fetch (uvx)" do
      preset = Presets.get("fetch")
      assert preset.command == "uvx"
      assert "mcp-server-fetch" in preset.args
    end

    test "returns preset for git (uvx)" do
      preset = Presets.get("git")
      assert preset.command == "uvx"
      assert "mcp-server-git" in preset.args
    end

    test "returns nil for unknown server" do
      assert Presets.get("unknown") == nil
      assert Presets.get("nonexistent") == nil
    end
  end

  describe "required_env/1" do
    test "returns required env var names for github" do
      assert "GITHUB_PERSONAL_ACCESS_TOKEN" in Presets.required_env("github")
    end

    test "returns required env var names for brave-search" do
      assert "BRAVE_API_KEY" in Presets.required_env("brave-search")
    end

    test "returns required env var names for slack" do
      env = Presets.required_env("slack")
      assert "SLACK_BOT_TOKEN" in env
      assert "SLACK_TEAM_ID" in env
    end

    test "returns empty list for servers without required env" do
      assert Presets.required_env("filesystem") == []
      assert Presets.required_env("memory") == []
      assert Presets.required_env("playwright") == []
    end

    test "returns empty list for unknown server" do
      assert Presets.required_env("unknown") == []
    end
  end
end
