defmodule SynapsisWeb.MemoryLive.IndexTest do
  use SynapsisWeb.ConnCase

  describe "memory page" do
    test "mounts and renders heading", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/settings/memory")
      assert html =~ "Memory"
      assert has_element?(view, "h1", "Memory")
    end

    test "shows breadcrumb navigation", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/memory")
      assert html =~ "Settings"
    end

    test "shows create form", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/memory")
      assert html =~ "Add Entry"
    end

    test "shows scope filter buttons", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/memory")
      assert html =~ "all"
      assert html =~ "global"
      assert html =~ "project"
      assert html =~ "session"
    end

    test "creates memory entry", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/memory")

      view
      |> form("form", %{"scope" => "global", "key" => "test-key", "content" => "test value"})
      |> render_submit()

      html = render(view)
      assert html =~ "test-key"
      assert html =~ "test value"
    end

    test "filters by scope", %{conn: conn} do
      %Synapsis.MemoryEntry{}
      |> Synapsis.MemoryEntry.changeset(%{scope: "global", key: "gk", content: "gc"})
      |> Synapsis.Repo.insert!()

      {:ok, view, _html} = live(conn, ~p"/settings/memory")

      view
      |> element(~s(button[phx-click="filter_scope"][phx-value-scope="global"]))
      |> render_click()

      html = render(view)
      assert html =~ "gk"
    end
  end
end
