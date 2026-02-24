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

    test "creates MCP config with SSE transport and URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/mcp")

      view
      |> form("form", %{
        "name" => "sse-server",
        "transport" => "sse",
        "url" => "http://localhost:8080/sse"
      })
      |> render_submit()

      html = render(view)
      assert html =~ "sse-server"
      assert html =~ "http://localhost:8080/sse"
    end

    test "creates MCP config with args and env", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/mcp")

      view
      |> form("form", %{
        "name" => "full-server",
        "transport" => "stdio",
        "command" => "node",
        "args" => "server.js\n--port=3000",
        "env" => "NODE_ENV=production\nAPI_KEY=test123"
      })
      |> render_submit()

      html = render(view)
      assert html =~ "full-server"
      assert html =~ "node"
    end

    test "displays env var count for config with env", %{conn: conn} do
      {:ok, _config} =
        %Synapsis.MCPConfig{}
        |> Synapsis.MCPConfig.changeset(%{
          name: "env-server",
          transport: "stdio",
          command: "test",
          env: %{"KEY1" => "val1", "KEY2" => "val2"}
        })
        |> Synapsis.Repo.insert()

      {:ok, _view, html} = live(conn, ~p"/settings/mcp")
      assert html =~ "2 env var(s)"
    end

    test "displays args for config with args", %{conn: conn} do
      {:ok, _config} =
        %Synapsis.MCPConfig{}
        |> Synapsis.MCPConfig.changeset(%{
          name: "args-server",
          transport: "stdio",
          command: "npx",
          args: ["-y", "@test/server"]
        })
        |> Synapsis.Repo.insert()

      {:ok, _view, html} = live(conn, ~p"/settings/mcp")
      assert html =~ "-y @test/server"
    end

    test "delete_config with nonexistent id does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/mcp")
      html = render_hook(view, "delete_config", %{"id" => Ecto.UUID.generate()})
      assert is_binary(html)
    end

    test "heading displays MCP Servers", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/mcp")
      assert has_element?(view, "h1", "MCP Servers")
    end

    test "success flash shown after creating config", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/mcp")

      view
      |> form("form", %{
        "name" => "flash-test-#{:rand.uniform(100_000)}",
        "transport" => "stdio",
        "command" => "test"
      })
      |> render_submit()

      assert render(view) =~ "MCP server added"
    end
  end
end
