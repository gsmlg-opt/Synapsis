defmodule SynapsisWeb.WorkspaceLive.ExplorerTest do
  use SynapsisWeb.ConnCase

  # ADR-006 C4: workspace docs are file-backed under SYNAPSIS_WORKSPACE_ROOT
  # (defaults to File.cwd!); isolate each test in a fresh tmp root.
  setup do
    root = Path.join(System.tmp_dir!(), "synapsis_ws_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    System.put_env("SYNAPSIS_WORKSPACE_ROOT", root)

    on_exit(fn ->
      System.delete_env("SYNAPSIS_WORKSPACE_ROOT")
      File.rm_rf(root)
    end)

    :ok
  end

  describe "explorer page" do
    test "mounts and renders heading", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/workspace")
      assert html =~ "Workspace Explorer"
    end

    test "shows search bar", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workspace")
      assert has_element?(view, "input[name=query]")
    end

    test "shows empty state when no documents", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/workspace")
      assert html =~ "No documents found"
    end

    test "lists documents after creating some", %{conn: conn} do
      Synapsis.Workspace.write("/shared/notes/explorer-test.md", "# Test", %{author: "test"})

      {:ok, _view, html} = live(conn, ~p"/workspace?path=/shared/notes")
      assert html =~ "explorer-test.md"
    end

    test "navigates to parent path", %{conn: conn} do
      Synapsis.Workspace.write("/shared/notes/nav-test.md", "content", %{author: "test"})

      {:ok, view, _html} = live(conn, ~p"/workspace?path=/shared/notes")
      assert has_element?(view, "el-dm-button", "Up")
    end

    test "selects a document and shows preview", %{conn: conn} do
      {:ok, resource} =
        Synapsis.Workspace.write("/shared/notes/preview-test.md", "Preview content here", %{
          author: "test"
        })

      {:ok, view, _html} = live(conn, ~p"/workspace?path=/shared/notes")

      html =
        view
        |> element("[phx-click=select][phx-value-id=\"#{resource.id}\"]")
        |> render_click()

      assert html =~ "Preview content here"
    end

    test "search returns matching documents", %{conn: conn} do
      Synapsis.Workspace.write(
        "/shared/notes/searchable-phoenix.md",
        "Phoenix framework is great for web applications",
        %{author: "test"}
      )

      {:ok, view, _html} = live(conn, ~p"/workspace")

      html =
        view
        |> element("form")
        |> render_submit(%{query: "phoenix framework"})

      assert html =~ "searchable-phoenix.md"
    end

    test "edit button shows editor with document content", %{conn: conn} do
      {:ok, resource} =
        Synapsis.Workspace.write("/shared/notes/edit-btn-test.md", "Editable content", %{
          author: "test"
        })

      {:ok, view, _html} = live(conn, ~p"/workspace?path=/shared/notes")

      view
      |> element("[phx-click=select][phx-value-id=\"#{resource.id}\"]")
      |> render_click()

      html =
        view
        |> element("[phx-click=edit]")
        |> render_click()

      assert html =~ "Editable content"
      assert html =~ "Save"
      assert html =~ "Cancel"
    end

    test "save edit updates document content", %{conn: conn} do
      {:ok, resource} =
        Synapsis.Workspace.write("/shared/notes/save-edit-test.md", "Original", %{author: "test"})

      {:ok, view, _html} = live(conn, ~p"/workspace?path=/shared/notes")

      view
      |> element("[phx-click=select][phx-value-id=\"#{resource.id}\"]")
      |> render_click()

      view
      |> element("[phx-click=edit]")
      |> render_click()

      html =
        view
        |> element("form[phx-submit=save_edit]")
        |> render_submit(%{content: "Updated content"})

      assert html =~ "Updated content"
    end

    test "delete removes document from list", %{conn: conn} do
      {:ok, resource} =
        Synapsis.Workspace.write("/shared/notes/delete-test.md", "To be deleted", %{
          author: "test"
        })

      {:ok, view, _html} = live(conn, ~p"/workspace?path=/shared/notes")

      view
      |> element("[phx-click=select][phx-value-id=\"#{resource.id}\"]")
      |> render_click()

      html =
        view
        |> element("[phx-click=delete][phx-value-id=\"#{resource.id}\"]")
        |> render_click()

      refute html =~ "delete-test.md"
    end

    test "clear search returns to browsing mode", %{conn: conn} do
      Synapsis.Workspace.write("/shared/notes/clear-test.md", "content", %{author: "test"})

      {:ok, view, _html} = live(conn, ~p"/workspace?path=/shared/notes")

      view
      |> element("form")
      |> render_submit(%{query: "content"})

      html =
        view
        |> element("[phx-click=clear_search]")
        |> render_click()

      refute html =~ "Clear"
    end
  end
end
