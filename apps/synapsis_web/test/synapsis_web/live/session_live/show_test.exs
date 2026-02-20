defmodule SynapsisWeb.SessionLive.ShowTest do
  use SynapsisWeb.ConnCase

  setup do
    {:ok, project} =
      %Synapsis.Project{}
      |> Synapsis.Project.changeset(%{
        path: "/tmp/sess_show_#{:rand.uniform(100_000)}",
        slug: "sess-show"
      })
      |> Synapsis.Repo.insert()

    {:ok, session} =
      %Synapsis.Session{}
      |> Synapsis.Session.changeset(%{
        project_id: project.id,
        provider: "anthropic",
        model: "claude-sonnet-4-20250514",
        title: "Show Test Session"
      })
      |> Synapsis.Repo.insert()

    %{project: project, session: session}
  end

  describe "session show page" do
    test "mounts and renders session title", %{conn: conn, project: project, session: session} do
      {:ok, _view, html} =
        live(conn, ~p"/projects/#{project.id}/sessions/#{session.id}")

      assert html =~ "Show Test Session"
    end

    test "displays provider and model label", %{conn: conn, project: project, session: session} do
      {:ok, _view, html} =
        live(conn, ~p"/projects/#{project.id}/sessions/#{session.id}")

      assert html =~ "anthropic/claude-sonnet-4-20250514"
    end

    test "renders agent mode toggle buttons", %{conn: conn, project: project, session: session} do
      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.id}/sessions/#{session.id}")

      assert has_element?(view, "button", "build")
      assert has_element?(view, "button", "plan")
    end

    test "switch_agent event changes the agent mode", %{
      conn: conn,
      project: project,
      session: session
    } do
      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.id}/sessions/#{session.id}")

      # Default agent is "build"
      html = render(view)
      assert html =~ "build"

      # Switch to plan mode
      html = view |> element("button", "plan") |> render_click()
      assert html =~ "plan"
    end

    test "sidebar shows the current session", %{conn: conn, project: project, session: session} do
      {:ok, _view, html} =
        live(conn, ~p"/projects/#{project.id}/sessions/#{session.id}")

      assert html =~ "Show Test Session"
    end

    test "renders new session button in sidebar", %{
      conn: conn,
      project: project,
      session: session
    } do
      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.id}/sessions/#{session.id}")

      assert has_element?(view, "button", "+ New Session")
    end

    test "redirects with flash on invalid session", %{conn: conn, project: project} do
      bad_id = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: "/projects/" <> _}}} =
               live(conn, ~p"/projects/#{project.id}/sessions/#{bad_id}")
    end
  end
end
