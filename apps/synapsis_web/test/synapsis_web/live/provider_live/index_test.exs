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
  end
end
