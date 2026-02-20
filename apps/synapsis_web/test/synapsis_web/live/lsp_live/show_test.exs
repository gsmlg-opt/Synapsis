defmodule SynapsisWeb.LSPLive.ShowTest do
  use SynapsisWeb.ConnCase

  setup do
    {:ok, config} =
      %Synapsis.LSPConfig{}
      |> Synapsis.LSPConfig.changeset(%{language: "elixir", command: "elixir-ls"})
      |> Synapsis.Repo.insert()

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
end
