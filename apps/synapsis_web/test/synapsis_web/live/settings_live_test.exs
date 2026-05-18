defmodule SynapsisWeb.SettingsLiveTest do
  use SynapsisWeb.ConnCase

  describe "settings page" do
    test "mounts and renders heading", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/settings")
      assert html =~ "Settings"
      assert has_element?(view, "h1", "Settings")
    end

    test "renders providers link", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")
      assert html =~ "Providers"
      assert html =~ "Manage LLM provider configurations and API keys."
    end

    test "renders memory link", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")
      assert html =~ "Memory"
      assert html =~ "Manage persistent memory entries across scopes."
    end

    test "does not render agent skills link", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")
      refute html =~ ~p"/settings/skills"
      refute html =~ "Create and edit skill definitions with custom prompts."
    end

    test "does not render MCP servers link", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")
      refute html =~ ~p"/settings/mcp"
      refute html =~ "Configure Model Context Protocol server connections."
    end

    test "does not render LSP servers link", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")
      refute html =~ ~p"/settings/lsp"
      refute html =~ "LSP Servers"
      refute html =~ "Configure Language Server Protocol integrations."
    end

    test "heading is present and page mounts correctly", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      # Verify the page renders with the expected structure
      assert has_element?(view, "h1", "Settings")
      assert page_title(view) =~ "Synapsis"
    end

    test "renders default model link", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")
      assert html =~ "Default Model"
      assert html =~ "View default, fast, and expert model tiers per provider."
    end

    test "renders theme control in settings content", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      assert has_element?(view, "[data-testid='settings-theme-switcher']")
    end

    test "all setting cards are rendered", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")
      assert html =~ ~p"/settings/providers"
      assert html =~ ~p"/settings/models"
      assert html =~ ~p"/settings/memory"
      refute html =~ ~p"/settings/lsp"
    end

    test "each card has a heading and description", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      assert has_element?(view, "[slot=\"header\"]", "Providers")
      assert has_element?(view, "[slot=\"header\"]", "Default Model")
      assert has_element?(view, "[slot=\"header\"]", "Memory")
      refute has_element?(view, "[slot=\"header\"]", "LSP Servers")
    end
  end
end
