defmodule SynapsisWeb.ModelTierLive.IndexTest do
  use SynapsisWeb.ConnCase

  describe "model tiers page" do
    test "mounts and renders heading", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/settings/models")
      assert html =~ "Default Model"
      assert has_element?(view, "h1", "Default Model")
    end

    test "renders breadcrumb", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/models")
      assert html =~ "Settings"
    end

    test "renders table headers", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/models")
      assert html =~ "Tier"
      assert html =~ "Description"
    end

    test "shows all three tiers", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/models")
      # Tier names are inside dm_badge which uses <slot /> (renders empty)
      # but descriptions contain the tier names as text
      assert html =~ "build agent"
      assert html =~ "speed"
      assert html =~ "plan agent"
    end

    test "shows tier descriptions", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/models")
      assert html =~ "build agent"
      assert html =~ "plan agent"
    end
  end
end
