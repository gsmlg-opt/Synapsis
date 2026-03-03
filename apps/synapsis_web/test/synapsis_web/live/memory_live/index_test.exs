defmodule SynapsisWeb.MemoryLive.IndexTest do
  use SynapsisWeb.ConnCase

  defp create_memory_entry(content) do
    %Synapsis.MemoryEntry{}
    |> Synapsis.MemoryEntry.changeset(%{scope: "global", key: "CLAUDE.md", content: content})
    |> Synapsis.Repo.insert!()
  end

  describe "memory page" do
    test "mounts and renders heading", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/memory")
      assert has_element?(view, "h1", "Memory")
    end

    test "shows breadcrumb navigation", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/memory")
      assert html =~ "Settings"
    end

    test "shows Edit button by default", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/memory")
      assert html =~ "Edit"
    end

    test "shows empty state when no entry", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/memory")
      assert html =~ "No memory content yet"
    end

    test "displays existing content readonly", %{conn: conn} do
      create_memory_entry("Hello from memory")
      {:ok, _view, html} = live(conn, ~p"/settings/memory")
      assert html =~ "Hello from memory"
    end

    test "content displayed with whitespace preserved", %{conn: conn} do
      create_memory_entry("line one\nline two")
      {:ok, _view, html} = live(conn, ~p"/settings/memory")
      assert html =~ "whitespace-pre-wrap"
      assert html =~ "line one\nline two"
    end

    test "clicking Edit shows textarea", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/memory")

      view |> element("button", "Edit") |> render_click()

      assert has_element?(view, "textarea[name=content]")
    end

    test "clicking Edit hides Edit button", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/memory")

      view |> element("button", "Edit") |> render_click()

      html = render(view)
      refute html =~ ~r/<button[^>]*>.*Edit.*<\/button>/s
      assert html =~ "Save"
    end

    test "edit mode shows Save and Cancel buttons", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/memory")

      view |> element("button", "Edit") |> render_click()

      assert has_element?(view, "button", "Save")
      assert has_element?(view, "button", "Cancel")
    end

    test "cancel returns to readonly without saving", %{conn: conn} do
      create_memory_entry("original content")
      {:ok, view, _html} = live(conn, ~p"/settings/memory")

      view |> element("button", "Edit") |> render_click()
      view |> element("button", "Cancel") |> render_click()

      html = render(view)
      assert html =~ "original content"
      refute has_element?(view, "textarea")
    end

    test "save persists new content", %{conn: conn} do
      create_memory_entry("old content")
      {:ok, view, _html} = live(conn, ~p"/settings/memory")

      view |> element("button", "Edit") |> render_click()

      view
      |> form("#memory-form", %{"content" => "new content"})
      |> render_submit()

      html = render(view)
      assert html =~ "new content"
      refute has_element?(view, "textarea")
    end

    test "save shows success flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/memory")

      view |> element("button", "Edit") |> render_click()

      view
      |> form("#memory-form", %{"content" => "some content"})
      |> render_submit()

      assert render(view) =~ "Memory saved"
    end

    test "save creates entry when none exists", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/memory")

      view |> element("button", "Edit") |> render_click()

      view
      |> form("#memory-form", %{"content" => "brand new content"})
      |> render_submit()

      html = render(view)
      assert html =~ "brand new content"
      refute html =~ "No memory content yet"
    end

    test "edit mode textarea contains current content", %{conn: conn} do
      create_memory_entry("pre-existing text")
      {:ok, view, _html} = live(conn, ~p"/settings/memory")

      view |> element("button", "Edit") |> render_click()

      html = render(view)
      assert html =~ "pre-existing text"
      assert has_element?(view, "textarea[name=content]")
    end
  end
end
