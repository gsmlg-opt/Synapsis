defmodule SynapsisWeb.LSPLive.IndexTest do
  use SynapsisWeb.ConnCase

  alias Synapsis.{Repo, PluginConfig}

  defp create_lsp_config(attrs) do
    %PluginConfig{}
    |> PluginConfig.changeset(Map.merge(%{type: "lsp"}, attrs))
    |> Repo.insert!()
  end

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

    test "shows Add LSP Server button", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/lsp")
      assert html =~ "Add LSP Server"
    end

    test "shows preset selector on /new", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/lsp/new")
      assert html =~ "Select a Language Server"
      assert html =~ "elixir"
      assert html =~ "typescript"
      assert html =~ "go"
      assert html =~ "python"
      assert html =~ "rust"
      assert html =~ "c_cpp"
    end

    test "selecting a preset shows form with pre-filled command", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/lsp/new")

      html =
        view
        |> element(~s(button[phx-click="select_preset"][phx-value-name="elixir"]))
        |> render_click()

      assert html =~ "elixir-ls"
      assert html =~ "Add"
    end

    test "creates LSP config from preset", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/lsp/new")

      view
      |> element(~s(button[phx-click="select_preset"][phx-value-name="go"]))
      |> render_click()

      view
      |> form("form")
      |> render_submit()

      flash = assert_redirect(view, "/settings/lsp")
      assert flash["info"] == "LSP server added"
    end

    test "deletes LSP config", %{conn: conn} do
      config = create_lsp_config(%{name: "rust", command: "rust-analyzer"})

      {:ok, view, html} = live(conn, ~p"/settings/lsp")
      assert html =~ "rust"

      view
      |> element(~s(button[phx-click="delete_config"][phx-value-id="#{config.id}"]))
      |> render_click()

      html = render(view)
      refute html =~ "rust-analyzer"
    end

    test "lists multiple LSP configs", %{conn: conn} do
      create_lsp_config(%{name: "go", command: "gopls"})
      create_lsp_config(%{name: "typescript", command: "typescript-language-server"})

      {:ok, _view, html} = live(conn, ~p"/settings/lsp")
      assert html =~ "go"
      assert html =~ "gopls"
      assert html =~ "typescript"
      assert html =~ "typescript-language-server"
    end

    test "already-added languages are indicated in preset selector", %{conn: conn} do
      create_lsp_config(%{name: "elixir", command: "elixir-ls"})

      {:ok, _view, html} = live(conn, ~p"/settings/lsp/new")
      assert html =~ "Already configured"
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
      config = create_lsp_config(%{name: "ruby", command: "solargraph"})

      {:ok, _view, html} = live(conn, ~p"/settings/lsp")
      assert html =~ "/settings/lsp/#{config.id}"
    end

    test "empty state message shown when no configs", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/lsp")
      assert html =~ "No LSP servers configured"
    end

    test "back_to_presets returns to preset grid", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/lsp/new")

      view
      |> element(~s(button[phx-click="select_preset"][phx-value-name="elixir"]))
      |> render_click()

      html =
        view
        |> element(~s(button[phx-click="back_to_presets"]))
        |> render_click()

      assert html =~ "Select a Language Server"
    end
  end
end
