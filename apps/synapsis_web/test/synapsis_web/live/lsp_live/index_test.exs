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

    test "shows Custom LSP and Import JSON buttons", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/lsp")
      assert html =~ "Custom LSP"
      assert html =~ "Import JSON"
    end

    test "shows all built-in LSP presets", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/lsp")
      assert html =~ "Built-in Language Servers"
      assert html =~ "typescript"
      assert html =~ "gopls"
      assert html =~ "pyright"
      assert html =~ "rust-analyzer"
      assert html =~ "clangd"
      assert html =~ "elixir-ls"
      assert html =~ "intelephense"
      assert html =~ "sourcekit-lsp"
      assert html =~ "kotlin-lsp"
      assert html =~ "csharp-ls"
      assert html =~ "jdtls"
      assert html =~ "lua-language-server"
      assert html =~ "ruby-lsp"
    end

    test "built-in presets show Enable button when not configured", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/lsp")
      assert has_element?(view, ~s(button[phx-click="enable_builtin"][phx-value-name="gopls"]))
    end

    test "enable_builtin creates config in database", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/lsp")

      view
      |> element(~s(button[phx-click="enable_builtin"][phx-value-name="gopls"]))
      |> render_click()

      assert Repo.get_by(PluginConfig, name: "gopls", type: "lsp")
    end

    test "enabled built-in shows Disable button and Edit link", %{conn: conn} do
      config = create_lsp_config(%{name: "gopls", command: "gopls", auto_start: true})

      {:ok, view, html} = live(conn, ~p"/settings/lsp")
      assert has_element?(view, ~s(button[phx-click="disable_builtin"][phx-value-name="gopls"]))
      assert html =~ "/settings/lsp/#{config.id}"
    end

    test "disable_builtin removes config from database", %{conn: conn} do
      create_lsp_config(%{name: "gopls", command: "gopls", auto_start: true})

      {:ok, view, _html} = live(conn, ~p"/settings/lsp")

      view
      |> element(~s(button[id^="btn-"][phx-click="disable_builtin"][phx-value-name="gopls"]))
      |> render_click()

      refute Repo.get_by(PluginConfig, name: "gopls", type: "lsp")
    end

    test "toggle_auto_start flips the auto_start flag", %{conn: conn} do
      config = create_lsp_config(%{name: "gopls", command: "gopls", auto_start: false})

      {:ok, view, _html} = live(conn, ~p"/settings/lsp")

      view
      |> element(~s(input[phx-click="toggle_auto_start"][phx-value-id="#{config.id}"]))
      |> render_click()

      updated = Repo.get!(PluginConfig, config.id)
      assert updated.auto_start == true
    end

    test "lists configured built-in servers", %{conn: conn} do
      create_lsp_config(%{name: "gopls", command: "gopls"})
      create_lsp_config(%{name: "typescript", command: "typescript-language-server"})

      {:ok, _view, html} = live(conn, ~p"/settings/lsp")
      assert html =~ "gopls"
      assert html =~ "typescript"
    end

    test "custom LSP form on /new", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/lsp/new")
      assert html =~ "Add Custom LSP Server"
      assert html =~ "Name"
      assert html =~ "Command"
    end

    test "creates custom LSP config", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/lsp/new")

      view
      |> form(~s(form[phx-submit="create_custom"]),
        name: "my-lsp",
        command: "my-lsp-server",
        args: "--stdio"
      )
      |> render_submit()

      flash = assert_redirect(view, "/settings/lsp")
      assert flash["info"] == "Custom LSP server added"
      assert Repo.get_by(PluginConfig, name: "my-lsp", type: "lsp")
    end

    test "custom LSP appears in Custom section", %{conn: conn} do
      create_lsp_config(%{name: "my-custom", command: "my-custom-lsp"})

      {:ok, _view, html} = live(conn, ~p"/settings/lsp")
      assert html =~ "Custom Language Servers"
      assert html =~ "my-custom"
    end

    test "deletes custom LSP config", %{conn: conn} do
      config = create_lsp_config(%{name: "my-custom", command: "my-custom-lsp"})

      {:ok, view, _html} = live(conn, ~p"/settings/lsp")

      view
      |> element(~s(button[id^="btn-"][phx-click="delete_config"][phx-value-id="#{config.id}"]))
      |> render_click()

      refute Repo.get(PluginConfig, config.id)
    end

    test "delete_config with nonexistent id does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/lsp")
      html = render_hook(view, "delete_config", %{"id" => Ecto.UUID.generate()})
      assert is_binary(html)
    end

    test "import_json creates LSP configs from JSON", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/lsp")

      view |> element(~s(button[phx-click="show_import"])) |> render_click()

      json =
        Jason.encode!(%{
          "my-lang" => %{"command" => "my-lang-server", "args" => ["--stdio"]}
        })

      html =
        view
        |> form(~s(form[phx-submit="import_json"]), %{"json" => json})
        |> render_submit()

      assert html =~ "Imported 1 LSP server"
      assert Repo.get_by(PluginConfig, name: "my-lang", type: "lsp")
    end

    test "import_json skips already configured servers", %{conn: conn} do
      create_lsp_config(%{name: "gopls", command: "gopls"})

      {:ok, view, _html} = live(conn, ~p"/settings/lsp")
      view |> element(~s(button[phx-click="show_import"])) |> render_click()

      json = Jason.encode!(%{"gopls" => %{"command" => "gopls"}})

      html =
        view
        |> form(~s(form[phx-submit="import_json"]), %{"json" => json})
        |> render_submit()

      assert html =~ "No new servers imported"
    end

    test "import_json shows error for invalid JSON", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/lsp")
      view |> element(~s(button[phx-click="show_import"])) |> render_click()

      html =
        view
        |> form(~s(form[phx-submit="import_json"]), %{"json" => "not json"})
        |> render_submit()

      assert html =~ "Invalid JSON"
    end
  end
end
