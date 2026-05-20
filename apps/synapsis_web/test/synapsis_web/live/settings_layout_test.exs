defmodule SynapsisWeb.SettingsLayoutTest do
  use SynapsisWeb.ConnCase

  alias Synapsis.{MemoryEvent, PluginConfig, ProviderConfig, Repo, SemanticMemory, Skill}

  @static_settings_paths [
    "/settings",
    "/settings/providers",
    "/settings/providers/new",
    "/settings/models",
    "/settings/memory",
    "/settings/memory/new",
    "/settings/skills",
    "/settings/mcp",
    "/settings/mcp/new",
    "/settings/lsp",
    "/settings/lsp/new"
  ]

  test "all settings pages render the shared left menu with MCP servers", %{conn: conn} do
    dynamic_paths = create_dynamic_settings_paths()

    for path <- @static_settings_paths ++ dynamic_paths do
      {:ok, view, _html} = live(conn, path)

      assert has_element?(view, "[data-testid='settings-sidebar']"),
             "expected settings sidebar on #{path}"

      assert has_element?(
               view,
               "[data-testid='settings-sidebar'] a[href='/settings/mcp']",
               "MCP Servers"
             ),
             "expected MCP Servers menu item on #{path}"
    end
  end

  defp create_dynamic_settings_paths do
    provider =
      %ProviderConfig{}
      |> ProviderConfig.changeset(%{
        name: "layout-provider-#{System.unique_integer([:positive])}",
        type: "anthropic",
        api_key_encrypted: "test-key"
      })
      |> Repo.insert!()

    Repo.delete_all(MemoryEvent)
    Repo.delete_all(SemanticMemory)

    memory =
      %SemanticMemory{}
      |> SemanticMemory.changeset(%{
        scope: "shared",
        scope_id: "",
        kind: "fact",
        title: "Layout Memory",
        summary: "Used by the settings layout test",
        tags: ["layout"],
        source: "human",
        importance: 0.5,
        confidence: 0.8,
        freshness: 1.0,
        contributed_by: "test"
      })
      |> Repo.insert!()

    skill =
      %Skill{}
      |> Skill.changeset(%{
        name: "layout-skill-#{System.unique_integer([:positive])}",
        scope: "global",
        description: "Used by the settings layout test",
        system_prompt_fragment: "Keep layout tests focused."
      })
      |> Repo.insert!()

    mcp_config =
      %PluginConfig{}
      |> PluginConfig.changeset(%{
        type: "mcp",
        name: "layout-mcp-#{System.unique_integer([:positive])}",
        transport: "stdio",
        command: "npx"
      })
      |> Repo.insert!()

    lsp_config =
      %PluginConfig{}
      |> PluginConfig.changeset(%{
        type: "lsp",
        name: "layout-lsp-#{System.unique_integer([:positive])}",
        command: "elixir-ls",
        args: ["--stdio"]
      })
      |> Repo.insert!()

    [
      "/settings/providers/#{provider.id}",
      "/settings/memory/#{memory.id}",
      "/settings/skills/#{skill.id}",
      "/settings/mcp/#{mcp_config.id}",
      "/settings/lsp/#{lsp_config.id}"
    ]
  end
end
