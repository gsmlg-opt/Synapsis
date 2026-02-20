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
  end
end
