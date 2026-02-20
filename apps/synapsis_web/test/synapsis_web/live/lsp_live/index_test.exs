defmodule SynapsisWeb.LSPLive.IndexTest do
  use SynapsisWeb.ConnCase

  describe "LSP servers page" do
    test "mounts and renders heading", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/settings/lsp")
      assert html =~ "LSP Servers"
      assert has_element?(view, "h1", "LSP Servers")
    end

    test "shows breadcrumb navigation", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/lsp")
      assert html =~ "Settings"
    end

    test "shows add form", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/lsp")
      assert html =~ "Language"
      assert html =~ "Command"
      assert html =~ "Add"
    end

    test "creates LSP config", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/lsp")

      view
      |> form("form", %{"language" => "elixir", "command" => "elixir-ls"})
      |> render_submit()

      html = render(view)
      assert html =~ "elixir"
      assert html =~ "elixir-ls"
    end

    test "deletes LSP config", %{conn: conn} do
      {:ok, config} =
        %Synapsis.LSPConfig{}
        |> Synapsis.LSPConfig.changeset(%{language: "rust", command: "rust-analyzer"})
        |> Synapsis.Repo.insert()

      {:ok, view, html} = live(conn, ~p"/settings/lsp")
      assert html =~ "rust"

      view
      |> element(~s(button[phx-click="delete_config"][phx-value-id="#{config.id}"]))
      |> render_click()

      html = render(view)
      refute html =~ "rust-analyzer"
    end
  end
end
