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

    test "renders skills link", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")
      assert html =~ "Skills"
      assert html =~ "Create and edit skill definitions with custom prompts."
    end

    test "renders MCP servers link", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")
      assert html =~ "MCP Servers"
      assert html =~ "Configure Model Context Protocol server connections."
    end

    test "renders LSP servers link", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")
      assert html =~ "LSP Servers"
      assert html =~ "Configure Language Server Protocol integrations."
    end

    test "heading is present and page mounts correctly", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      # Verify the page renders with the expected structure
      assert has_element?(view, "h1", "Settings")
      assert page_title(view) =~ "Synapsis"
    end

    test "all five setting cards are rendered", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")
      assert html =~ ~p"/settings/providers"
      assert html =~ ~p"/settings/memory"
      assert html =~ ~p"/settings/skills"
      assert html =~ ~p"/settings/mcp"
      assert html =~ ~p"/settings/lsp"
    end

    test "each card has a heading and description", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      assert has_element?(view, "h2", "Providers")
      assert has_element?(view, "h2", "Memory")
      assert has_element?(view, "h2", "Skills")
      assert has_element?(view, "h2", "MCP Servers")
      assert has_element?(view, "h2", "LSP Servers")
    end
  end
end
