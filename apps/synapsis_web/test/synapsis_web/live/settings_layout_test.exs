defmodule SynapsisWeb.SettingsLayoutTest do
  use SynapsisWeb.ConnCase

  alias Synapsis.{MCPConfigs, Memory, Providers, Skills}

  setup do
    Synapsis.DataCase.reset_memory_store()
    :ok
  end

  @static_settings_paths [
    "/settings",
    "/settings/providers",
    "/settings/providers/new",
    "/settings/models",
    "/settings/memory",
    "/settings/memory/new",
    "/settings/skills",
    "/settings/mcp",
    "/settings/mcp/new"
  ]

  test "all settings pages render the shared left menu with MCP servers", %{conn: conn} do
    dynamic_paths = create_dynamic_settings_paths()

    for path <- @static_settings_paths ++ dynamic_paths do
      {:ok, view, _html} = live(conn, path)

      assert has_element?(view, "[data-testid='settings-sidebar']"),
             "expected settings sidebar on #{path}"

      assert has_element?(view, "aside[data-testid='settings-sidebar'].w-64.bg-secondary"),
             "expected settings sidebar to use the full-height left rail on #{path}"

      assert has_element?(view, "[data-testid='settings-sidebar'] .app-left-menu"),
             "expected settings sidebar to use the shared left menu styling on #{path}"

      assert has_element?(
               view,
               "[data-testid='settings-sidebar'] a[href='/settings/mcp']",
               "MCP Servers"
             ),
             "expected MCP Servers menu item on #{path}"
    end
  end

  test "settings overview is active on the root settings page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(
             view,
             "[data-testid='settings-sidebar'] a[href='/settings'][aria-current='page']",
             "Overview"
           )
  end

  test "nested settings pages activate their specific menu item", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/providers/new")

    assert has_element?(
             view,
             "[data-testid='settings-sidebar'] a[href='/settings/providers'][aria-current='page']",
             "Providers"
           )

    refute has_element?(
             view,
             "[data-testid='settings-sidebar'] a[href='/settings'][aria-current='page']",
             "Overview"
           )
  end

  test "unlisted settings sections do not activate overview", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/skills")

    refute has_element?(
             view,
             "[data-testid='settings-sidebar'] a[href='/settings'][aria-current='page']",
             "Overview"
           )
  end

  defp create_dynamic_settings_paths do
    {:ok, provider} =
      Providers.create(%{
        name: "layout-provider-#{System.unique_integer([:positive])}",
        type: "anthropic",
        api_key_encrypted: "test-key"
      })

    {:ok, memory} =
      Memory.store_semantic(%{
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

    {:ok, skill} =
      Skills.create(%{
        name: "layout-skill-#{System.unique_integer([:positive])}",
        scope: "global",
        description: "Used by the settings layout test",
        system_prompt_fragment: "Keep layout tests focused."
      })

    {:ok, mcp_config} =
      MCPConfigs.create(%{
        name: "layout-mcp-#{System.unique_integer([:positive])}",
        transport: "stdio",
        command: "npx"
      })

    [
      "/settings/providers/#{provider.id}",
      "/settings/memory/#{memory.id}",
      "/settings/skills/#{skill.id}",
      "/settings/mcp/#{mcp_config.id}"
    ]
  end
end
