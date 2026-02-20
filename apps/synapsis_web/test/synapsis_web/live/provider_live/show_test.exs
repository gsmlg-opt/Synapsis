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
  end
end
