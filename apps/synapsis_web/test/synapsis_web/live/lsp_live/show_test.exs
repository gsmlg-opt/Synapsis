defmodule SynapsisWeb.LSPLive.ShowTest do
  use SynapsisWeb.ConnCase

  alias Synapsis.{Repo, PluginConfig}

  setup do
    {:ok, config} =
      %PluginConfig{}
      |> PluginConfig.changeset(%{
        type: "lsp",
        name: "elixir",
        command: "elixir-ls",
        args: ["--stdio"]
      })
      |> Repo.insert()

    %{config: config}
  end

  test "renders config details", %{conn: conn, config: config} do
    {:ok, _view, html} = live(conn, ~p"/settings/lsp/#{config.id}")
    assert html =~ "elixir"
    assert html =~ "elixir-ls"
  end

  test "redirects for missing config", %{conn: conn} do
    {:error, {:live_redirect, %{to: "/settings/lsp"}}} =
      live(conn, ~p"/settings/lsp/#{Ecto.UUID.generate()}")
  end

  test "updates config", %{conn: conn, config: config} do
    {:ok, view, _html} = live(conn, ~p"/settings/lsp/#{config.id}")

    view
    |> form("form", %{"command" => "new-elixir-ls"})
    |> render_submit()

    html = render(view)
    assert html =~ "new-elixir-ls"
  end

  test "shows breadcrumb with Settings / LSP Servers / name", %{conn: conn, config: config} do
    {:ok, _view, html} = live(conn, ~p"/settings/lsp/#{config.id}")
    assert html =~ "Settings"
    assert html =~ "LSP Servers"
    assert html =~ config.name
  end

  test "shows auto-start checkbox", %{conn: conn, config: config} do
    {:ok, _view, html} = live(conn, ~p"/settings/lsp/#{config.id}")
    assert html =~ "Auto-start"
    assert html =~ ~s(name="auto_start")
  end

  test "shows root path field", %{conn: conn, config: config} do
    {:ok, _view, html} = live(conn, ~p"/settings/lsp/#{config.id}")
    assert html =~ "Root Path"
    assert html =~ ~s(name="root_path")
  end

  test "shows args display", %{conn: conn, config: config} do
    {:ok, _view, html} = live(conn, ~p"/settings/lsp/#{config.id}")
    assert html =~ "Args"
    assert html =~ "--stdio"
  end

  test "shows save button", %{conn: conn, config: config} do
    {:ok, view, _html} = live(conn, ~p"/settings/lsp/#{config.id}")
    assert has_element?(view, "el-dm-button[type='submit']", "Save Changes")
  end

  test "heading displays the name", %{conn: conn, config: config} do
    {:ok, view, _html} = live(conn, ~p"/settings/lsp/#{config.id}")
    assert has_element?(view, "h1", config.name)
  end

  test "update_config shows success flash", %{conn: conn, config: config} do
    {:ok, view, _html} = live(conn, ~p"/settings/lsp/#{config.id}")

    view
    |> form("form", %{"command" => "updated-ls"})
    |> render_submit()

    assert render(view) =~ "LSP server updated"
  end

  test "update_config with root_path persists it", %{conn: conn, config: config} do
    {:ok, view, _html} = live(conn, ~p"/settings/lsp/#{config.id}")

    view
    |> form("form", %{"command" => config.command, "root_path" => "/home/user/project"})
    |> render_submit()

    updated = Repo.get(PluginConfig, config.id)
    assert updated.root_path == "/home/user/project"
  end

  test "update_config with auto_start=false disables it", %{conn: conn, config: config} do
    {:ok, view, _html} = live(conn, ~p"/settings/lsp/#{config.id}")

    view
    |> form("form", %{"command" => config.command, "auto_start" => "false"})
    |> render_submit()

    updated = Repo.get(PluginConfig, config.id)
    assert updated.auto_start == false
  end
end
