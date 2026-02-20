defmodule SynapsisWeb.MCPLive.ShowTest do
  use SynapsisWeb.ConnCase

  setup do
    {:ok, config} =
      %Synapsis.MCPConfig{}
      |> Synapsis.MCPConfig.changeset(%{
        name: "test-server",
        transport: "stdio",
        command: "npx test-server"
      })
      |> Synapsis.Repo.insert()

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
end
