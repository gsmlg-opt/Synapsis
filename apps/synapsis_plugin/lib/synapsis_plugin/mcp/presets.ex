defmodule SynapsisPlugin.MCP.Presets do
  @moduledoc """
  Data-driven MCP server presets for popular community and official servers.

  Provides preset configurations for well-known MCP servers, and seeding
  of default configurations into the database.
  """

  alias Synapsis.{Repo, PluginConfig}
  import Ecto.Query, only: [from: 2]

  @presets [
    %{
      name: "filesystem",
      description: "Secure file operations with configurable directory access controls",
      command: "npx",
      args: ["-y", "@modelcontextprotocol/server-filesystem"],
      env: %{},
      transport: "stdio"
    },
    %{
      name: "github",
      description: "GitHub repository management — issues, PRs, branches, code search",
      command: "npx",
      args: ["-y", "@modelcontextprotocol/server-github"],
      env: %{"GITHUB_PERSONAL_ACCESS_TOKEN" => ""},
      transport: "stdio"
    },
    %{
      name: "playwright",
      description: "Browser automation — navigate, click, fill forms, take screenshots",
      command: "npx",
      args: ["-y", "@playwright/mcp@latest"],
      env: %{},
      transport: "stdio"
    },
    %{
      name: "memory",
      description: "Knowledge graph-based persistent memory across sessions",
      command: "npx",
      args: ["-y", "@modelcontextprotocol/server-memory"],
      env: %{},
      transport: "stdio"
    },
    %{
      name: "brave-search",
      description: "Privacy-focused web search via Brave Search API",
      command: "npx",
      args: ["-y", "@modelcontextprotocol/server-brave-search"],
      env: %{"BRAVE_API_KEY" => ""},
      transport: "stdio"
    },
    %{
      name: "fetch",
      description: "Fetch web content and convert to markdown for LLM consumption",
      command: "uvx",
      args: ["mcp-server-fetch"],
      env: %{},
      transport: "stdio"
    },
    %{
      name: "git",
      description: "Read, search, and manipulate local Git repositories",
      command: "uvx",
      args: ["mcp-server-git"],
      env: %{},
      transport: "stdio"
    },
    %{
      name: "sequential-thinking",
      description: "Structured problem-solving through dynamic thought sequences",
      command: "npx",
      args: ["-y", "@modelcontextprotocol/server-sequential-thinking"],
      env: %{},
      transport: "stdio"
    },
    %{
      name: "postgres",
      description: "Read-only access to PostgreSQL databases — schema inspection and queries",
      command: "npx",
      args: ["-y", "@modelcontextprotocol/server-postgres"],
      env: %{},
      transport: "stdio"
    },
    %{
      name: "sqlite",
      description: "Read-only access to SQLite databases — inspect tables and run queries",
      command: "npx",
      args: ["-y", "@modelcontextprotocol/server-sqlite"],
      env: %{},
      transport: "stdio"
    },
    %{
      name: "puppeteer",
      description: "Headless browser automation via Puppeteer",
      command: "npx",
      args: ["-y", "@modelcontextprotocol/server-puppeteer"],
      env: %{},
      transport: "stdio"
    },
    %{
      name: "slack",
      description: "Interact with Slack workspaces — channels, messages, threads",
      command: "npx",
      args: ["-y", "@modelcontextprotocol/server-slack"],
      env: %{"SLACK_BOT_TOKEN" => "", "SLACK_TEAM_ID" => ""},
      transport: "stdio"
    }
  ]

  @doc "Return all MCP server presets."
  def all, do: @presets

  @doc "Get a preset by server name. Returns nil for unknown servers."
  def get(name) do
    Enum.find(@presets, &(&1.name == name))
  end

  @doc "Return names of presets already configured in the database."
  def configured_names do
    Repo.all(from(p in PluginConfig, where: p.type == "mcp", select: p.name))
  end

  @doc "Insert all presets into plugin_configs as type \"mcp\" (idempotent)."
  def seed_defaults do
    Enum.each(@presets, fn preset ->
      %PluginConfig{}
      |> PluginConfig.changeset(%{
        type: "mcp",
        name: preset.name,
        transport: preset.transport,
        command: preset.command,
        args: preset.args,
        env: preset.env,
        auto_start: false
      })
      |> Repo.insert(
        on_conflict: :nothing,
        conflict_target: [:name, :scope, :project_id]
      )
    end)

    :ok
  end

  @doc "Return the list of required environment variable names for a preset."
  def required_env(name) do
    case get(name) do
      nil ->
        []

      preset ->
        preset.env
        |> Enum.filter(fn {_k, v} -> v == "" end)
        |> Enum.map(fn {k, _v} -> k end)
    end
  end
end
