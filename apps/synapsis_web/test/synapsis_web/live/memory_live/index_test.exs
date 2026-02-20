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

    test "filter_scope hides entries of other scopes", %{conn: conn} do
      %Synapsis.MemoryEntry{}
      |> Synapsis.MemoryEntry.changeset(%{scope: "global", key: "global-only-key", content: "g"})
      |> Synapsis.Repo.insert!()

      %Synapsis.MemoryEntry{}
      |> Synapsis.MemoryEntry.changeset(%{
        scope: "project",
        key: "project-only-key",
        content: "p"
      })
      |> Synapsis.Repo.insert!()

      {:ok, view, _html} = live(conn, ~p"/settings/memory")

      view
      |> element(~s(button[phx-click="filter_scope"][phx-value-scope="project"]))
      |> render_click()

      html = render(view)
      assert html =~ "project-only-key"
      refute html =~ "global-only-key"
    end

    test "deletes a memory entry", %{conn: conn} do
      {:ok, entry} =
        %Synapsis.MemoryEntry{}
        |> Synapsis.MemoryEntry.changeset(%{scope: "global", key: "to-delete-key", content: "bye"})
        |> Synapsis.Repo.insert()

      {:ok, view, html} = live(conn, ~p"/settings/memory")
      assert html =~ "to-delete-key"

      view
      |> element(~s(button[phx-click="delete_entry"][phx-value-id="#{entry.id}"]))
      |> render_click()

      refute render(view) =~ "to-delete-key"
    end

    test "create_entry with empty key shows error flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/memory")
      view |> form("form", %{"scope" => "global", "key" => "", "content" => "some content"}) |> render_submit()
      assert render(view) =~ "Failed to create entry"
    end
  end
end
