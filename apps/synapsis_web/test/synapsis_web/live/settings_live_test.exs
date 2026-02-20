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
  end
end
