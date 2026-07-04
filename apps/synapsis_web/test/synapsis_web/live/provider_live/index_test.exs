defmodule SynapsisWeb.ProviderLive.IndexTest do
  use SynapsisWeb.ConnCase

  setup do
    clear_providers()
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
      create_provider(%{
        name: "test_provider_#{:rand.uniform(100_000)}",
        type: "anthropic",
        api_key_encrypted: "sk-test-key"
      })

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
        |> element(~s(el-dm-button[phx-click="back_to_presets"]))
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

    test "created provider survives a fresh page load from the config file", %{conn: conn} do
      name = "persisted-provider-#{:rand.uniform(100_000)}"
      {:ok, view, _html} = live(conn, ~p"/settings/providers/new")

      view
      |> element(~s(button[phx-click="select_preset"][phx-value-name="anthropic"]))
      |> render_click()

      view
      |> form("form[phx-submit]", %{"name" => name, "api_key" => "sk-test-123"})
      |> render_submit()

      assert_redirected(view, ~p"/settings/providers")
      :ok = Synapsis.Config.Store.reload(:provider)

      {:ok, _view, html} = live(conn, ~p"/settings/providers")
      assert html =~ name
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
      bypass = Bypass.open()
      Bypass.down(bypass)

      {:ok, view, _html} = live(conn, ~p"/settings/providers/new")

      view
      |> element(~s(button[phx-click="select_custom"][phx-value-type="openai"]))
      |> render_click()

      view
      |> form("form[phx-submit]", %{
        "name" => "my-local-llm",
        "base_url" => "http://localhost:#{bypass.port}",
        "api_key" => "none"
      })
      |> render_submit()

      flash = assert_redirected(view, ~p"/settings/providers")
      assert flash["info"] == "Provider created; model loading failed"
    end

    test "custom compatible provider creation loads models", %{conn: conn} do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => [%{"id" => "model-a"}]}))
      end)

      {:ok, view, _html} = live(conn, ~p"/settings/providers/new")

      view
      |> element(~s(button[phx-click="select_custom"][phx-value-type="openai"]))
      |> render_click()

      view
      |> form("form[phx-submit]", %{
        "name" => "my-compatible-llm",
        "base_url" => "http://localhost:#{bypass.port}/v1",
        "api_key" => "sk-test"
      })
      |> render_submit()

      flash = assert_redirected(view, ~p"/settings/providers")
      assert flash["info"] == "Provider created and models loaded"

      {:ok, provider} = Synapsis.Providers.get_by_name("my-compatible-llm")
      assert [%{"id" => "model-a"}] = provider.config["available_models"]
    end

    test "delete_provider event removes provider from grid", %{conn: conn} do
      name = "prov_del_#{:rand.uniform(100_000)}"

      provider =
        create_provider(%{
          name: name,
          type: "anthropic",
          api_key_encrypted: "sk-test-key"
        })

      {:ok, view, html} = live(conn, ~p"/settings/providers")
      assert html =~ name

      # dm_btn with confirm= generates two buttons with phx-click, use render_hook instead
      render_hook(view, "delete_provider", %{"id" => provider.id})

      refute render(view) =~ name
    end

    test "shows enabled badge for enabled provider", %{conn: conn} do
      create_provider(%{
        name: "enabled_prov_#{:rand.uniform(100_000)}",
        type: "anthropic",
        api_key_encrypted: "sk-key",
        enabled: true
      })

      {:ok, view, _html} = live(conn, ~p"/settings/providers")
      # dm_badge uses <slot /> which renders empty; check for badge-success class
      assert has_element?(view, "el-dm-badge[color=\"success\"]")
    end

    test "shows disabled badge for disabled provider", %{conn: conn} do
      create_provider(%{
        name: "disabled_prov_#{:rand.uniform(100_000)}",
        type: "openai_compat",
        api_key_encrypted: "sk-key",
        enabled: false
      })

      {:ok, view, _html} = live(conn, ~p"/settings/providers")
      # dm_badge uses <slot /> which renders empty; check for badge-error class
      assert has_element?(view, "el-dm-badge[color=\"error\"]")
    end

    test "shows base_url when set", %{conn: conn} do
      create_provider(%{
        name: "url_prov_#{:rand.uniform(100_000)}",
        type: "openai_compat",
        api_key_encrypted: "sk-key",
        base_url: "https://custom.api.example.com"
      })

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

  # ADR-006 C4: providers live in the file-backed Config.Store, not Ecto.
  defp create_provider(attrs) do
    {:ok, provider} = Synapsis.Providers.create(attrs)
    provider
  end

  defp clear_providers do
    {:ok, providers} = Synapsis.Providers.list()
    Enum.each(providers, fn p -> Synapsis.Providers.delete(p.id) end)
  end
end
