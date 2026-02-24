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

    test "create_config with empty command shows error flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/lsp")
      view |> form("form", %{"language" => "", "command" => ""}) |> render_submit()
      assert render(view) =~ "Failed to add LSP server"
    end

    test "lists multiple LSP configs", %{conn: conn} do
      for {lang, cmd} <- [{"go", "gopls"}, {"typescript", "typescript-language-server"}] do
        %Synapsis.LSPConfig{}
        |> Synapsis.LSPConfig.changeset(%{language: lang, command: cmd})
        |> Synapsis.Repo.insert!()
      end

      {:ok, _view, html} = live(conn, ~p"/settings/lsp")
      assert html =~ "go"
      assert html =~ "gopls"
      assert html =~ "typescript"
      assert html =~ "typescript-language-server"
    end

    test "success flash shown after creating config", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/lsp")

      view
      |> form("form", %{"language" => "python", "command" => "pyright"})
      |> render_submit()

      assert render(view) =~ "LSP server added"
    end

    test "delete_config with nonexistent id does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/lsp")
      html = render_hook(view, "delete_config", %{"id" => Ecto.UUID.generate()})
      assert is_binary(html)
    end

    test "heading displays LSP Servers", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/lsp")
      assert has_element?(view, "h1", "LSP Servers")
    end

    test "each config links to its show page", %{conn: conn} do
      {:ok, config} =
        %Synapsis.LSPConfig{}
        |> Synapsis.LSPConfig.changeset(%{language: "ruby", command: "solargraph"})
        |> Synapsis.Repo.insert()

      {:ok, _view, html} = live(conn, ~p"/settings/lsp")
      assert html =~ "/settings/lsp/#{config.id}"
    end
  end
end
