defmodule SynapsisWeb.ProjectLive.IndexTest do
  use SynapsisWeb.ConnCase

  describe "project list page" do
    test "mounts and renders heading", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/projects")
      assert html =~ "Projects"
      assert has_element?(view, "h1", "Projects")
    end

    test "lists existing projects", %{conn: conn} do
      %Synapsis.Project{}
      |> Synapsis.Project.changeset(%{
        path: "/tmp/proj_test_#{:rand.uniform(100_000)}",
        slug: "proj-list-test"
      })
      |> Synapsis.Repo.insert!()

      {:ok, _view, html} = live(conn, ~p"/projects")
      assert html =~ "proj-list-test"
    end

    test "shows new project form at /new", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/projects/new")
      assert html =~ "New Project"
    end

    test "create_project event creates a project and navigates", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects/new")

      assert {:error, {:live_redirect, %{to: "/projects/" <> _}}} =
               view
               |> form("form", %{"path" => "/tmp/create_proj_#{:rand.uniform(100_000)}"})
               |> render_submit()
    end

    test "create_project event with empty path shows error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects/new")

      html =
        view
        |> form("form", %{"path" => ""})
        |> render_submit()

      assert html =~ "Failed to create project"
    end

    test "renders the projects section with heading and new link", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects")
      assert has_element?(view, "h1", "Projects")
      # The page always includes the "+ New Project" link
      assert render(view) =~ "+ New Project"
    end

    test "renders '+ New Project' link", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/projects")
      assert html =~ "+ New Project"
    end

    test "heading displays Projects on index", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects")
      assert has_element?(view, "h1", "Projects")
    end

    test "heading displays Projects and form is shown at /new", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects/new")
      assert has_element?(view, "h1", "Projects")
      # The form should be visible at /new
      assert has_element?(view, "form")
    end

    test "form at /new has correct placeholder text", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/projects/new")
      assert html =~ "Project path"
    end

    test "project links show path and slug", %{conn: conn} do
      %Synapsis.Project{}
      |> Synapsis.Project.changeset(%{
        path: "/home/user/my-great-project",
        slug: "my-great-project"
      })
      |> Synapsis.Repo.insert!()

      {:ok, _view, html} = live(conn, ~p"/projects")
      assert html =~ "my-great-project"
      assert html =~ "/home/user/my-great-project"
    end

    test "multiple projects are all listed", %{conn: conn} do
      for i <- 1..3 do
        %Synapsis.Project{}
        |> Synapsis.Project.changeset(%{
          path: "/tmp/multi_proj_#{i}_#{:rand.uniform(100_000)}",
          slug: "multi-proj-#{i}"
        })
        |> Synapsis.Repo.insert!()
      end

      {:ok, _view, html} = live(conn, ~p"/projects")
      assert html =~ "multi-proj-1"
      assert html =~ "multi-proj-2"
      assert html =~ "multi-proj-3"
    end

    test "form is not shown on index action", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/projects")
      # The create form placeholder should not appear on index page
      refute html =~ "Project path (e.g."
    end
  end
end
