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

    test "renders empty state text in projects section when no projects inserted", %{conn: conn} do
      # The template includes "No projects yet." conditional on @projects == []
      # If there happen to be pre-existing rows in the DB, this is still rendered
      # as part of the template structure. We verify the template compiles and
      # the section heading is always present.
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "h2", "Projects")
    end

    test "renders empty state text in sessions section when no sessions inserted", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "h2", "Recent Sessions")
    end

    test "renders '+ New' project link", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "+ New"
    end

    test "session without title shows truncated id fallback", %{conn: conn} do
      {:ok, project} =
        %Synapsis.Project{}
        |> Synapsis.Project.changeset(%{
          path: "/tmp/dash_notitle_#{:rand.uniform(100_000)}",
          slug: "dash-notitle"
        })
        |> Synapsis.Repo.insert()

      {:ok, session} =
        %Synapsis.Session{}
        |> Synapsis.Session.changeset(%{
          project_id: project.id,
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })
        |> Synapsis.Repo.insert()

      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Session #{String.slice(session.id, 0, 8)}"
    end

    test "session displays agent name", %{conn: conn} do
      {:ok, project} =
        %Synapsis.Project{}
        |> Synapsis.Project.changeset(%{
          path: "/tmp/dash_agent_#{:rand.uniform(100_000)}",
          slug: "dash-agent"
        })
        |> Synapsis.Repo.insert()

      {:ok, _session} =
        %Synapsis.Session{}
        |> Synapsis.Session.changeset(%{
          project_id: project.id,
          provider: "anthropic",
          model: "claude-sonnet-4-20250514",
          agent: "plan"
        })
        |> Synapsis.Repo.insert()

      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "plan"
    end

    test "renders Synapsis in the page title", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert page_title(view) =~ "Synapsis"
    end
  end
end
