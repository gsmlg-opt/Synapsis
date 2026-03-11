defmodule SynapsisWeb.MCPLive.IndexTest do
  use SynapsisWeb.ConnCase

  alias Synapsis.{Repo, PluginConfig}

  defp create_mcp_config(attrs) do
    %PluginConfig{}
    |> PluginConfig.changeset(Map.merge(%{type: "mcp", transport: "stdio"}, attrs))
    |> Repo.insert!()
  end

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

    test "shows Add MCP Server button", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/mcp")
      assert html =~ "Add MCP Server"
    end

    test "shows preset selector on /new", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/mcp/new")
      assert html =~ "Select an MCP Server"
      assert html =~ "filesystem"
      assert html =~ "github"
      assert html =~ "playwright"
      assert html =~ "memory"
    end

    test "shows custom option in preset selector", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/mcp/new")
      assert html =~ "Custom MCP Server"
    end

    test "selecting a preset shows form with pre-filled command", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/mcp/new")

      html =
        view
        |> element(~s(button[phx-click="select_preset"][phx-value-name="filesystem"]))
        |> render_click()

      assert html =~ "npx"
      assert html =~ "Add MCP Server"
    end

    test "selecting custom shows editable form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/mcp/new")

      html =
        view
        |> element(~s(button[phx-click="select_custom"]))
        |> render_click()

      assert html =~ "New Custom MCP Server"
    end

    test "creates MCP config from preset", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/mcp/new")

      view
      |> element(~s(button[phx-click="select_preset"][phx-value-name="memory"]))
      |> render_click()

      view
      |> form("form")
      |> render_submit()

      flash = assert_redirect(view, "/settings/mcp")
      assert flash["info"] == "MCP server added"
    end

    test "creates MCP config from custom form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/mcp/new")

      view
      |> element(~s(button[phx-click="select_custom"]))
      |> render_click()

      view
      |> form("form", %{
        "name" => "custom-test",
        "command" => "npx -y test-server",
        "transport" => "stdio"
      })
      |> render_submit()

      flash = assert_redirect(view, "/settings/mcp")
      assert flash["info"] == "MCP server added"
    end

    test "deletes MCP config", %{conn: conn} do
      config = create_mcp_config(%{name: "deletable", command: "test-cmd"})

      {:ok, view, html} = live(conn, ~p"/settings/mcp")
      assert html =~ "deletable"

      view
      |> element(~s(button[id^="btn-"][phx-click="delete_config"][phx-value-id="#{config.id}"]))
      |> render_click()

      html = render(view)
      refute html =~ "deletable"
    end

    test "toggle_enabled switches auto_start", %{conn: conn} do
      config = create_mcp_config(%{name: "toggleable", command: "test", auto_start: false})

      {:ok, view, html} = live(conn, ~p"/settings/mcp")
      assert html =~ "Disabled"

      view
      |> element(~s(button[phx-click="toggle_enabled"][phx-value-id="#{config.id}"]))
      |> render_click()

      html = render(view)
      assert html =~ "Enabled"
    end

    test "already-added servers are indicated in preset selector", %{conn: conn} do
      create_mcp_config(%{name: "filesystem", command: "npx"})

      {:ok, _view, html} = live(conn, ~p"/settings/mcp/new")
      assert html =~ "Already configured"
    end

    test "displays env var count for config with env", %{conn: conn} do
      create_mcp_config(%{
        name: "env-server",
        command: "test",
        env: %{"KEY1" => "val1", "KEY2" => "val2"}
      })

      {:ok, _view, html} = live(conn, ~p"/settings/mcp")
      assert html =~ "2 env var(s)"
    end

    test "displays args for config with args", %{conn: conn} do
      create_mcp_config(%{
        name: "args-server",
        command: "npx",
        args: ["-y", "@test/server"]
      })

      {:ok, _view, html} = live(conn, ~p"/settings/mcp")
      assert html =~ "-y @test/server"
    end

    test "lists multiple MCP configs", %{conn: conn} do
      create_mcp_config(%{name: "server-a", command: "cmd-a"})
      create_mcp_config(%{name: "server-b", command: "cmd-b"})

      {:ok, _view, html} = live(conn, ~p"/settings/mcp")
      assert html =~ "server-a"
      assert html =~ "server-b"
    end

    test "delete_config with nonexistent id does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/mcp")
      html = render_hook(view, "delete_config", %{"id" => Ecto.UUID.generate()})
      assert is_binary(html)
    end

    test "empty state message shown when no configs", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/mcp")
      assert html =~ "No MCP servers configured"
    end

    test "back_to_presets returns to preset grid", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/mcp/new")

      view
      |> element(~s(button[phx-click="select_preset"][phx-value-name="filesystem"]))
      |> render_click()

      html =
        view
        |> element(~s(button[phx-click="back_to_presets"]))
        |> render_click()

      assert html =~ "Select an MCP Server"
    end

    test "preset with required env shows env textarea with placeholders", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/mcp/new")

      html =
        view
        |> element(~s(button[phx-click="select_preset"][phx-value-name="github"]))
        |> render_click()

      assert html =~ "GITHUB_PERSONAL_ACCESS_TOKEN"
      assert html =~ "Fill in the required environment variable values"
    end
  end
end
