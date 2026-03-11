defmodule SynapsisWeb.ProviderLive.IndexTest do
  use SynapsisWeb.ConnCase

  setup do
    Synapsis.Repo.delete_all(Synapsis.ProviderConfig)
    :ok
  end

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

    test "lists existing providers as grid cards", %{conn: conn} do
      {:ok, _} =
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

    test "new action shows preset grid", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/providers/new")
      assert html =~ "Select a Provider"
      assert html =~ "anthropic"
      assert html =~ "openai"
      assert html =~ "openrouter"
    end

    test "new action shows custom options", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/providers/new")
      assert html =~ "Custom"
      assert html =~ "OpenAI Compatible"
      assert html =~ "Anthropic Compatible"
    end

    test "selecting a preset shows form with editable name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/new")

      html =
        view
        |> element(~s(button[phx-click="select_preset"][phx-value-name="anthropic"]))
        |> render_click()

      assert html =~ "Add anthropic"
      assert html =~ "API Key"
      assert html =~ ~s(value="anthropic")
    end

    test "selecting custom shows form with editable base_url", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/new")

      html =
        view
        |> element(~s(button[phx-click="select_custom"][phx-value-type="openai"]))
        |> render_click()

      assert html =~ "New OpenAI Compatible"
      assert html =~ ~s(name="base_url")
    end

    test "back button returns to preset grid", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/new")

      view
      |> element(~s(button[phx-click="select_preset"][phx-value-name="anthropic"]))
      |> render_click()

      html =
        view
        |> element(~s(button[phx-click="back_to_presets"]))
        |> render_click()

      assert html =~ "Select a Provider"
    end

    test "preset can be created with custom name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/new")

      view
      |> element(~s(button[phx-click="select_preset"][phx-value-name="anthropic"]))
      |> render_click()

      view
      |> form("form[phx-submit]", %{"name" => "my-anthropic", "api_key" => "sk-test-123"})
      |> render_submit()

      flash = assert_redirected(view, ~p"/settings/providers")
      assert flash["info"] == "Provider created"
    end

    test "same preset can be added twice with different names", %{conn: conn} do
      # Create first
      {:ok, view, _html} = live(conn, ~p"/settings/providers/new")

      view
      |> element(~s(button[phx-click="select_preset"][phx-value-name="anthropic"]))
      |> render_click()

      view
      |> form("form[phx-submit]", %{"name" => "anthropic-work", "api_key" => "sk-work"})
      |> render_submit()

      # Create second
      {:ok, view2, _html} = live(conn, ~p"/settings/providers/new")

      view2
      |> element(~s(button[phx-click="select_preset"][phx-value-name="anthropic"]))
      |> render_click()

      view2
      |> form("form[phx-submit]", %{"name" => "anthropic-personal", "api_key" => "sk-personal"})
      |> render_submit()

      flash = assert_redirected(view2, ~p"/settings/providers")
      assert flash["info"] == "Provider created"
    end

    test "duplicate name shows error", %{conn: conn} do
      {:ok, _} =
        Synapsis.Providers.create(%{
          name: "taken-name",
          type: "anthropic",
          api_key_encrypted: "sk-key"
        })

      {:ok, view, _html} = live(conn, ~p"/settings/providers/new")

      view
      |> element(~s(button[phx-click="select_preset"][phx-value-name="anthropic"]))
      |> render_click()

      html =
        view
        |> form("form[phx-submit]", %{"name" => "taken-name", "api_key" => "sk-other"})
        |> render_submit()

      assert html =~ "Name already taken"
    end

    test "custom provider creation with base_url", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/new")

      view
      |> element(~s(button[phx-click="select_custom"][phx-value-type="openai"]))
      |> render_click()

      view
      |> form("form[phx-submit]", %{
        "name" => "my-local-llm",
        "base_url" => "http://localhost:11434",
        "api_key" => "none"
      })
      |> render_submit()

      flash = assert_redirected(view, ~p"/settings/providers")
      assert flash["info"] == "Provider created"
    end

    test "delete_provider event removes provider from grid", %{conn: conn} do
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

      # dm_btn with confirm= generates two buttons with phx-click, use render_hook instead
      render_hook(view, "delete_provider", %{"id" => provider.id})

      refute render(view) =~ name
    end

    test "shows enabled badge for enabled provider", %{conn: conn} do
      {:ok, _} =
        %Synapsis.ProviderConfig{}
        |> Synapsis.ProviderConfig.changeset(%{
          name: "enabled_prov_#{:rand.uniform(100_000)}",
          type: "anthropic",
          api_key_encrypted: "sk-key",
          enabled: true
        })
        |> Synapsis.Repo.insert()

      {:ok, view, _html} = live(conn, ~p"/settings/providers")
      # dm_badge uses <slot /> which renders empty; check for badge-success class
      assert has_element?(view, "span.badge-success")
    end

    test "shows disabled badge for disabled provider", %{conn: conn} do
      {:ok, _} =
        %Synapsis.ProviderConfig{}
        |> Synapsis.ProviderConfig.changeset(%{
          name: "disabled_prov_#{:rand.uniform(100_000)}",
          type: "openai_compat",
          api_key_encrypted: "sk-key",
          enabled: false
        })
        |> Synapsis.Repo.insert()

      {:ok, view, _html} = live(conn, ~p"/settings/providers")
      # dm_badge uses <slot /> which renders empty; check for badge-error class
      assert has_element?(view, "span.badge-error")
    end

    test "shows base_url when set", %{conn: conn} do
      {:ok, _} =
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

    test "form is hidden on index action", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/providers")
      refute html =~ "Select a Provider"
    end

    test "delete_provider with nonexistent id shows error flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers")
      html = render_hook(view, "delete_provider", %{"id" => Ecto.UUID.generate()})
      assert html =~ "Failed to delete provider"
    end

    test "empty state message shown when no providers", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/providers")
      assert html =~ "No providers configured"
    end
  end
end
