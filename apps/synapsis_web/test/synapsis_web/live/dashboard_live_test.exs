defmodule SynapsisWeb.DashboardLiveTest do
  use SynapsisWeb.ConnCase

  describe "dashboard page" do
    test "mounts and renders heading", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/")
      assert html =~ "Synapsis"
      assert has_element?(view, "h1", "Dashboard")
    end

    test "shows projects section heading", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "h2", "Projects")
    end

    test "shows recent sessions section heading", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "h2", "Recent Sessions")
    end

    test "renders appbar navigation links", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Providers"
      assert html =~ "MCP"
      assert html =~ "LSP"
      assert html =~ "Settings"
    end

    test "lists projects when they exist", %{conn: conn} do
      {:ok, project} =
        %Synapsis.Project{}
        |> Synapsis.Project.changeset(%{
          path: "/tmp/dash_proj_#{:rand.uniform(100_000)}",
          slug: "dash-proj"
        })
        |> Synapsis.Repo.insert()

      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ project.slug
      assert html =~ project.path
    end

    test "lists recent sessions when they exist", %{conn: conn} do
      {:ok, project} =
        %Synapsis.Project{}
        |> Synapsis.Project.changeset(%{
          path: "/tmp/dash_sess_#{:rand.uniform(100_000)}",
          slug: "dash-sess"
        })
        |> Synapsis.Repo.insert()

      {:ok, session} =
        %Synapsis.Session{}
        |> Synapsis.Session.changeset(%{
          project_id: project.id,
          provider: "anthropic",
          model: "claude-sonnet-4-20250514",
          title: "Test Dashboard Session"
        })
        |> Synapsis.Repo.insert()

      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ session.title
      assert html =~ "anthropic/claude-sonnet-4-20250514"
    end
  end
end
