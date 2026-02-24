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
        |> Synapsis.MemoryEntry.changeset(%{
          scope: "global",
          key: "to-delete-key",
          content: "bye"
        })
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

      view
      |> form("form", %{"scope" => "global", "key" => "", "content" => "some content"})
      |> render_submit()

      assert render(view) =~ "Failed to create entry"
    end

    test "create_entry with empty content shows error flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/memory")

      view
      |> form("form", %{"scope" => "global", "key" => "test-key", "content" => ""})
      |> render_submit()

      assert render(view) =~ "Failed to create entry"
    end

    test "filter back to 'all' shows all entries", %{conn: conn} do
      %Synapsis.MemoryEntry{}
      |> Synapsis.MemoryEntry.changeset(%{scope: "global", key: "g-all", content: "gc"})
      |> Synapsis.Repo.insert!()

      %Synapsis.MemoryEntry{}
      |> Synapsis.MemoryEntry.changeset(%{scope: "project", key: "p-all", content: "pc"})
      |> Synapsis.Repo.insert!()

      {:ok, view, _html} = live(conn, ~p"/settings/memory")

      # Filter to project only
      view
      |> element(~s(button[phx-click="filter_scope"][phx-value-scope="project"]))
      |> render_click()

      html = render(view)
      assert html =~ "p-all"
      refute html =~ "g-all"

      # Filter back to all
      view
      |> element(~s(button[phx-click="filter_scope"][phx-value-scope="all"]))
      |> render_click()

      html = render(view)
      assert html =~ "g-all"
      assert html =~ "p-all"
    end

    test "filtering by session scope shows only session entries", %{conn: conn} do
      %Synapsis.MemoryEntry{}
      |> Synapsis.MemoryEntry.changeset(%{scope: "session", key: "sess-key", content: "sc"})
      |> Synapsis.Repo.insert!()

      %Synapsis.MemoryEntry{}
      |> Synapsis.MemoryEntry.changeset(%{scope: "global", key: "glob-key", content: "gc"})
      |> Synapsis.Repo.insert!()

      {:ok, view, _html} = live(conn, ~p"/settings/memory")

      view
      |> element(~s(button[phx-click="filter_scope"][phx-value-scope="session"]))
      |> render_click()

      html = render(view)
      assert html =~ "sess-key"
      refute html =~ "glob-key"
    end

    test "create_entry shows success flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/memory")

      view
      |> form("form", %{
        "scope" => "global",
        "key" => "flash-key-#{:rand.uniform(100_000)}",
        "content" => "flash content"
      })
      |> render_submit()

      assert render(view) =~ "Memory entry created"
    end

    test "heading displays Memory", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/memory")
      assert has_element?(view, "h1", "Memory")
    end

    test "entry content is displayed", %{conn: conn} do
      %Synapsis.MemoryEntry{}
      |> Synapsis.MemoryEntry.changeset(%{
        scope: "global",
        key: "content-display-key",
        content: "This is the displayed content body."
      })
      |> Synapsis.Repo.insert!()

      {:ok, _view, html} = live(conn, ~p"/settings/memory")
      assert html =~ "This is the displayed content body."
    end

    test "entry displays its scope badge", %{conn: conn} do
      %Synapsis.MemoryEntry{}
      |> Synapsis.MemoryEntry.changeset(%{
        scope: "project",
        key: "scope-badge-key",
        content: "content"
      })
      |> Synapsis.Repo.insert!()

      {:ok, _view, html} = live(conn, ~p"/settings/memory")
      assert html =~ "scope-badge-key"
      assert html =~ "project"
    end

    test "delete_entry with nonexistent id does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/memory")
      html = render_hook(view, "delete_entry", %{"id" => Ecto.UUID.generate()})
      assert is_binary(html)
    end

    test "create_entry with project scope sets scope correctly", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/memory")

      view
      |> form("form", %{
        "scope" => "project",
        "key" => "proj-scope-test-#{:rand.uniform(100_000)}",
        "content" => "proj content"
      })
      |> render_submit()

      html = render(view)
      assert html =~ "proj content"
    end
  end
end
