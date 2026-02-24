defmodule SynapsisWeb.ProviderLive.IndexTest do
  use SynapsisWeb.ConnCase

  describe "provider index page" do
    test "mounts and renders heading", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/settings/providers")
      assert html =~ "Providers"
      assert has_element?(view, "h1", "Providers")
    end

    test "renders settings breadcrumb", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/providers")
      assert html =~ "Settings"
    end

    test "renders add provider link", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/providers")
      assert html =~ "+ Add Provider"
    end

    test "lists existing providers", %{conn: conn} do
      {:ok, _provider} =
        %Synapsis.ProviderConfig{}
        |> Synapsis.ProviderConfig.changeset(%{
          name: "test_provider_#{:rand.uniform(100_000)}",
          type: "anthropic",
          api_key_encrypted: "sk-test-key"
        })
        |> Synapsis.Repo.insert()

      {:ok, _view, html} = live(conn, ~p"/settings/providers")
      assert html =~ "test_provider_"
      assert html =~ "anthropic"
    end

    test "new action shows the form", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/providers/new")
      assert html =~ "Create Provider"
    end

    test "create_provider event creates a provider and shows success flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/new")
      name = "prov_create_#{:rand.uniform(100_000)}"

      view
      |> form("form", %{
        "name" => name,
        "type" => "anthropic",
        "base_url" => "",
        "api_key" => "sk-test-123"
      })
      |> render_submit()

      html = render(view)
      assert html =~ "Provider created"
    end

    test "create_provider event shows error flash on failure", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/new")

      # Submit with empty name to trigger validation failure
      view
      |> form("form", %{"name" => "", "type" => "anthropic", "api_key" => ""})
      |> render_submit()

      html = render(view)
      assert html =~ "Failed to create provider"
    end

    test "delete_provider event removes provider from list", %{conn: conn} do
      name = "prov_del_#{:rand.uniform(100_000)}"

      {:ok, provider} =
        %Synapsis.ProviderConfig{}
        |> Synapsis.ProviderConfig.changeset(%{
          name: name,
          type: "anthropic",
          api_key_encrypted: "sk-test-key"
        })
        |> Synapsis.Repo.insert()

      {:ok, view, html} = live(conn, ~p"/settings/providers")
      assert html =~ name

      view
      |> element(~s(button[phx-click="delete_provider"][phx-value-id="#{provider.id}"]))
      |> render_click()

      refute render(view) =~ name
    end

    test "shows enabled status for enabled provider", %{conn: conn} do
      {:ok, _provider} =
        %Synapsis.ProviderConfig{}
        |> Synapsis.ProviderConfig.changeset(%{
          name: "enabled_prov_#{:rand.uniform(100_000)}",
          type: "anthropic",
          api_key_encrypted: "sk-key",
          enabled: true
        })
        |> Synapsis.Repo.insert()

      {:ok, _view, html} = live(conn, ~p"/settings/providers")
      assert html =~ "Enabled"
    end

    test "shows disabled status for disabled provider", %{conn: conn} do
      {:ok, _provider} =
        %Synapsis.ProviderConfig{}
        |> Synapsis.ProviderConfig.changeset(%{
          name: "disabled_prov_#{:rand.uniform(100_000)}",
          type: "openai_compat",
          api_key_encrypted: "sk-key",
          enabled: false
        })
        |> Synapsis.Repo.insert()

      {:ok, _view, html} = live(conn, ~p"/settings/providers")
      assert html =~ "Disabled"
    end

    test "shows base_url when set", %{conn: conn} do
      {:ok, _provider} =
        %Synapsis.ProviderConfig{}
        |> Synapsis.ProviderConfig.changeset(%{
          name: "url_prov_#{:rand.uniform(100_000)}",
          type: "openai_compat",
          api_key_encrypted: "sk-key",
          base_url: "https://custom.api.example.com"
        })
        |> Synapsis.Repo.insert()

      {:ok, _view, html} = live(conn, ~p"/settings/providers")
      assert html =~ "https://custom.api.example.com"
    end

    test "form at /new shows type selector with all options", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/providers/new")
      assert html =~ "Anthropic"
      assert html =~ "OpenAI Compatible"
      assert html =~ "Google"
    end

    test "form is hidden on index action", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/providers")
      refute html =~ "Create Provider"
    end

    test "delete_provider with nonexistent id shows error flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers")
      html = render_hook(view, "delete_provider", %{"id" => Ecto.UUID.generate()})
      assert html =~ "Failed to delete provider"
    end

    test "heading displays Providers", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers")
      assert has_element?(view, "h1", "Providers")
    end
  end
end
