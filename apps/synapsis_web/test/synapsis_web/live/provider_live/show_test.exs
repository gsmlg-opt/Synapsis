defmodule SynapsisWeb.ProviderLive.ShowTest do
  use SynapsisWeb.ConnCase

  setup do
    {:ok, provider} =
      %Synapsis.ProviderConfig{}
      |> Synapsis.ProviderConfig.changeset(%{
        name: "test-show-provider-#{:rand.uniform(100_000)}",
        type: "anthropic",
        api_key_encrypted: "sk-ant-test-key"
      })
      |> Synapsis.Repo.insert()

    {:ok, provider: provider}
  end

  describe "provider show page" do
    test "mounts and displays provider name", %{conn: conn, provider: provider} do
      {:ok, _view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
      assert html =~ provider.name
    end

    test "shows provider type (read-only)", %{conn: conn, provider: provider} do
      {:ok, _view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
      assert html =~ provider.type
    end

    test "shows api key is set indicator", %{conn: conn, provider: provider} do
      {:ok, _view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
      assert html =~ "Key is set"
    end

    test "shows save button", %{conn: conn, provider: provider} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")
      assert has_element?(view, "button[type='submit']", "Save Changes")
    end

    test "redirects for unknown provider id", %{conn: conn} do
      id = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: "/settings/providers"}}} =
               live(conn, ~p"/settings/providers/#{id}")
    end

    test "update_provider event updates base_url", %{conn: conn, provider: provider} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")

      html =
        view
        |> form("form", %{
          "base_url" => "https://custom.api.example.com/v1",
          "enabled" => "true"
        })
        |> render_submit()

      assert html =~ "Provider updated"
    end

    test "shows breadcrumb with Settings / Providers / name", %{conn: conn, provider: provider} do
      {:ok, _view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
      assert html =~ "Settings"
      assert html =~ "Providers"
      assert html =~ provider.name
    end

    test "update_provider with enabled=false disables the provider", %{
      conn: conn,
      provider: provider
    } do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")

      view
      |> form("form", %{"base_url" => "", "enabled" => "false"})
      |> render_submit()

      {:ok, updated} = Synapsis.Providers.get(provider.id)
      assert updated.enabled == false
    end

    test "update_provider with empty api_key does not overwrite existing key", %{
      conn: conn,
      provider: provider
    } do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")

      view
      |> form("form", %{"base_url" => "", "enabled" => "true", "api_key" => ""})
      |> render_submit()

      {:ok, updated} = Synapsis.Providers.get(provider.id)
      assert updated.api_key_encrypted != nil
    end

    test "update_provider with new api_key updates it", %{conn: conn, provider: provider} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")

      view
      |> form("form", %{"base_url" => "", "enabled" => "true", "api_key" => "new-secret-key"})
      |> render_submit()

      html = render(view)
      assert html =~ "Provider updated"
    end

    test "provider without api_key does not show 'Key is set'", %{conn: conn} do
      {:ok, no_key_provider} =
        %Synapsis.ProviderConfig{}
        |> Synapsis.ProviderConfig.changeset(%{
          name: "no-key-prov-#{:rand.uniform(100_000)}",
          type: "openai_compat"
        })
        |> Synapsis.Repo.insert()

      {:ok, _view, html} = live(conn, ~p"/settings/providers/#{no_key_provider.id}")
      refute html =~ "Key is set"
    end

    test "heading displays the provider name", %{conn: conn, provider: provider} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")
      assert has_element?(view, "h1", provider.name)
    end

    test "form has base_url input field", %{conn: conn, provider: provider} do
      {:ok, _view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
      assert html =~ "Base URL"
      assert html =~ "base_url"
    end

    test "form has enabled checkbox", %{conn: conn, provider: provider} do
      {:ok, _view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
      assert html =~ "Enabled"
      assert html =~ ~s(name="enabled")
    end

    test "update_provider with new base_url persists it", %{conn: conn, provider: provider} do
      {:ok, view, _html} = live(conn, ~p"/settings/providers/#{provider.id}")

      view
      |> form("form", %{
        "base_url" => "https://new-base.example.com/v2",
        "enabled" => "true"
      })
      |> render_submit()

      {:ok, updated} = Synapsis.Providers.get(provider.id)
      assert updated.base_url == "https://new-base.example.com/v2"
    end
  end
end
