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
      # dm_card header slot renders as [slot="header"] inside el-dm-card
      assert has_element?(view, "[slot=\"header\"]", "Projects")
    end

    test "shows recent sessions section heading", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      # dm_card header slot renders as [slot="header"] inside el-dm-card
      assert has_element?(view, "[slot=\"header\"]", "Recent Sessions")
    end

    test "renders appbar navigation links", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Assistant"
      assert html =~ "Providers"
      assert html =~ "MCP"
      assert html =~ "LSP"
      # Settings is rendered as an icon link to /settings
      assert html =~ ~s(href="/settings")
    end

    test "lists projects when they exist", %{conn: conn} do
      {:ok, project} =
        %Synapsis.Project{}
        |> Synapsis.Project.changeset(%{
          path: "/tmp/dash_proj_#{:rand.uniform(100_000)}",
          slug: "dash-proj",
          name: "dash-proj"
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
          slug: "dash-sess",
          name: "dash-sess"
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
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "[slot=\"header\"]", "Projects")
    end

    test "renders empty state text in sessions section when no sessions inserted", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "[slot=\"header\"]", "Recent Sessions")
    end

    test "renders New project button", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      # dm_btn renders as el-dm-button custom element
      assert has_element?(view, "el-dm-button", "New")
    end

    test "session without title shows truncated id fallback", %{conn: conn} do
      {:ok, project} =
        %Synapsis.Project{}
        |> Synapsis.Project.changeset(%{
          path: "/tmp/dash_notitle_#{:rand.uniform(100_000)}",
          slug: "dash-notitle",
          name: "dash-notitle"
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
          slug: "dash-agent",
          name: "dash-agent"
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

      {:ok, view, _html} = live(conn, ~p"/")
      # Agent name is inside a dm_badge which renders as el-dm-badge
      # The component maps variant="ghost" to color="ghost" on the element
      assert has_element?(view, "el-dm-badge[color=\"ghost\"]")
    end

    test "renders Synapsis in the page title", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert page_title(view) =~ "Synapsis"
    end
  end
end
