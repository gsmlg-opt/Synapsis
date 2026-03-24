defmodule SynapsisWeb.MCPLive.ShowTest do
  use SynapsisWeb.ConnCase

  alias Synapsis.{Repo, PluginConfig}

  setup do
    {:ok, config} =
      %PluginConfig{}
      |> PluginConfig.changeset(%{
        type: "mcp",
        name: "test-server",
        transport: "stdio",
        command: "npx test-server"
      })
      |> Repo.insert()

    %{config: config}
  end

  test "renders config details", %{conn: conn, config: config} do
    {:ok, _view, html} = live(conn, ~p"/settings/mcp/#{config.id}")
    assert html =~ "test-server"
    assert html =~ "npx test-server"
  end

  test "redirects for missing config", %{conn: conn} do
    {:error, {:live_redirect, %{to: "/settings/mcp"}}} =
      live(conn, ~p"/settings/mcp/#{Ecto.UUID.generate()}")
  end

  test "updates config", %{conn: conn, config: config} do
    {:ok, view, _html} = live(conn, ~p"/settings/mcp/#{config.id}")

    view
    |> form("form", %{"command" => "npx updated-server"})
    |> render_submit()

    html = render(view)
    assert html =~ "npx updated-server"
  end

  test "shows breadcrumb with Settings / MCP Servers / name", %{conn: conn, config: config} do
    {:ok, _view, html} = live(conn, ~p"/settings/mcp/#{config.id}")
    assert html =~ "Settings"
    assert html =~ "MCP Servers"
    assert html =~ config.name
  end

  test "shows transport selector with current value", %{conn: conn, config: config} do
    {:ok, _view, html} = live(conn, ~p"/settings/mcp/#{config.id}")
    assert html =~ "Transport"
    assert html =~ "stdio"
    assert html =~ "SSE"
  end

  test "shows auto-start checkbox", %{conn: conn, config: config} do
    {:ok, _view, html} = live(conn, ~p"/settings/mcp/#{config.id}")
    assert html =~ "Auto-start on startup"
    assert html =~ ~s(name="auto_start")
  end

  test "heading displays config name", %{conn: conn, config: config} do
    {:ok, view, _html} = live(conn, ~p"/settings/mcp/#{config.id}")
    assert has_element?(view, "h1", config.name)
  end

  test "update_config shows success flash", %{conn: conn, config: config} do
    {:ok, view, _html} = live(conn, ~p"/settings/mcp/#{config.id}")

    view
    |> form("form", %{"command" => "updated-cmd"})
    |> render_submit()

    assert render(view) =~ "MCP server updated"
  end

  test "shows save button", %{conn: conn, config: config} do
    {:ok, view, _html} = live(conn, ~p"/settings/mcp/#{config.id}")
    assert has_element?(view, "el-dm-button[type='submit']", "Save Changes")
  end

  test "shows URL field", %{conn: conn, config: config} do
    {:ok, _view, html} = live(conn, ~p"/settings/mcp/#{config.id}")
    assert html =~ "URL"
    assert html =~ ~s(name="url")
  end

  test "shows args textarea", %{conn: conn, config: config} do
    {:ok, _view, html} = live(conn, ~p"/settings/mcp/#{config.id}")
    assert html =~ "Arguments (one per line)"
    assert html =~ ~s(name="args")
  end

  test "shows env textarea", %{conn: conn, config: config} do
    {:ok, _view, html} = live(conn, ~p"/settings/mcp/#{config.id}")
    assert html =~ "Environment Variables"
    assert html =~ ~s(name="env")
  end

  test "config with env vars displays them formatted", %{conn: conn} do
    {:ok, config_with_env} =
      %PluginConfig{}
      |> PluginConfig.changeset(%{
        type: "mcp",
        name: "env-show-test",
        transport: "stdio",
        command: "test",
        env: %{"TOKEN" => "abc123", "SECRET" => "xyz789"}
      })
      |> Repo.insert()

    {:ok, _view, html} = live(conn, ~p"/settings/mcp/#{config_with_env.id}")
    assert html =~ "TOKEN=abc123"
    assert html =~ "SECRET=xyz789"
  end

  test "config with args displays them one per line", %{conn: conn} do
    {:ok, config_with_args} =
      %PluginConfig{}
      |> PluginConfig.changeset(%{
        type: "mcp",
        name: "args-show-test",
        transport: "stdio",
        command: "test",
        args: ["--verbose", "--port=8080"]
      })
      |> Repo.insert()

    {:ok, _view, html} = live(conn, ~p"/settings/mcp/#{config_with_args.id}")
    assert html =~ "--verbose"
    assert html =~ "--port=8080"
  end

  test "submitting form with empty args and env clears them", %{conn: conn, config: config} do
    {:ok, view, _html} = live(conn, ~p"/settings/mcp/#{config.id}")

    view
    |> form("form", %{"command" => "some-cmd", "args" => "", "env" => ""})
    |> render_submit()

    html = render(view)
    assert html =~ "MCP server updated"
  end

  test "submitting form with args as newline-delimited list", %{conn: conn, config: config} do
    {:ok, view, _html} = live(conn, ~p"/settings/mcp/#{config.id}")

    view
    |> form("form", %{"command" => "cmd", "args" => "--verbose\n--debug\n"})
    |> render_submit()

    html = render(view)
    assert html =~ "MCP server updated"
    assert html =~ "--verbose"
    assert html =~ "--debug"
  end

  test "submitting form with env vars as KEY=VALUE lines", %{conn: conn, config: config} do
    {:ok, view, _html} = live(conn, ~p"/settings/mcp/#{config.id}")

    view
    |> form("form", %{
      "command" => "cmd",
      "env" => "MYVAR=hello\nOTHER=world\nINVALID_LINE_NO_EQUALS\n"
    })
    |> render_submit()

    html = render(view)
    assert html =~ "MCP server updated"
    assert html =~ "MYVAR=hello"
    assert html =~ "OTHER=world"
  end

  test "submitting form with sse transport updates transport", %{conn: conn, config: config} do
    {:ok, view, _html} = live(conn, ~p"/settings/mcp/#{config.id}")

    view
    |> form("form", %{"command" => "test", "transport" => "sse", "url" => "http://example.com"})
    |> render_submit()

    html = render(view)
    assert html =~ "MCP server updated"
  end

  test "auto_start checkbox — submitting with false value", %{conn: conn, config: config} do
    {:ok, view, _html} = live(conn, ~p"/settings/mcp/#{config.id}")

    view
    |> form("form", %{"command" => "test", "auto_start" => "false"})
    |> render_submit()

    assert render(view) =~ "MCP server updated"
  end
end
