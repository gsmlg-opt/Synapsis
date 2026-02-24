defmodule SynapsisWeb.MCPLive.IndexTest do
  use SynapsisWeb.ConnCase

  describe "MCP servers page" do
    test "mounts and renders heading", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/settings/mcp")
      assert html =~ "MCP Servers"
      assert has_element?(view, "h1", "MCP Servers")
    end

    test "shows breadcrumb navigation", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/mcp")
      assert html =~ "Settings"
    end

    test "shows add form", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/mcp")
      assert html =~ "Add"
    end

    test "creates MCP config", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/mcp")

      view
      |> form("form", %{
        "name" => "test-mcp",
        "transport" => "stdio",
        "command" => "npx -y test-server"
      })
      |> render_submit()

      html = render(view)
      assert html =~ "test-mcp"
    end

    test "deletes MCP config", %{conn: conn} do
      {:ok, config} =
        %Synapsis.MCPConfig{}
        |> Synapsis.MCPConfig.changeset(%{
          name: "deletable",
          transport: "stdio",
          command: "test-cmd"
        })
        |> Synapsis.Repo.insert()

      {:ok, view, html} = live(conn, ~p"/settings/mcp")
      assert html =~ "deletable"

      view
      |> element(~s(button[phx-click="delete_config"][phx-value-id="#{config.id}"]))
      |> render_click()

      html = render(view)
      refute html =~ "deletable"
    end

    test "create_config with empty name shows error flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/mcp")

      view
      |> form("form", %{"name" => "", "command" => "npx", "args" => "", "env" => ""})
      |> render_submit()

      assert render(view) =~ "Failed to add MCP server"
    end
  end
end
