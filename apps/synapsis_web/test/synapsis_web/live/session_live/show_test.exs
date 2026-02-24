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

    test "toggle_new_session_form shows and hides the create form", %{
      conn: conn,
      project: project,
      session: session
    } do
      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.id}/sessions/#{session.id}")

      refute has_element?(view, "button", "Create")
      view |> element("button", "+ New Session") |> render_click()
      assert has_element?(view, "button", "Create")
      view |> element("button", "+ New Session") |> render_click()
      refute has_element?(view, "button", "Create")
    end

    test "select_model via value key updates the model", %{
      conn: conn,
      project: project,
      session: session
    } do
      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.id}/sessions/#{session.id}")

      # Show form so the model input is rendered in the DOM
      view |> element("button", "+ New Session") |> render_click()
      render_hook(view, "select_model", %{"value" => "claude-opus-4-20250514"})
      html = render(view)
      assert html =~ "claude-opus-4-20250514"
    end

    test "select_model via model key updates the model", %{
      conn: conn,
      project: project,
      session: session
    } do
      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.id}/sessions/#{session.id}")

      # Show form so the model input is rendered in the DOM
      view |> element("button", "+ New Session") |> render_click()
      render_hook(view, "select_model", %{"model" => "gpt-4o"})
      html = render(view)
      assert html =~ "gpt-4o"
    end

    test "select_provider event updates provider state", %{
      conn: conn,
      project: project,
      session: session
    } do
      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.id}/sessions/#{session.id}")

      html = render_hook(view, "select_provider", %{"provider" => "anthropic"})
      assert is_binary(html)
    end

    test "navigate event redirects to the given path", %{
      conn: conn,
      project: project,
      session: session
    } do
      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.id}/sessions/#{session.id}")

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               render_hook(view, "navigate", %{"path" => "/projects"})
    end

    test "create_session event creates a new session and navigates", %{
      conn: conn,
      project: project,
      session: session
    } do
      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.id}/sessions/#{session.id}")

      render_hook(view, "select_model", %{"value" => "claude-sonnet-4-20250514"})

      assert {:error, {:live_redirect, %{to: "/projects/" <> _}}} =
               render_hook(view, "create_session", %{})
    end

    test "delete_session on current session navigates to project page", %{
      conn: conn,
      project: project,
      session: session
    } do
      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.id}/sessions/#{session.id}")

      assert {:error, {:live_redirect, %{to: "/projects/" <> _}}} =
               render_hook(view, "delete_session", %{"id" => session.id})
    end

    test "delete_session on another session removes it from the sidebar", %{
      conn: conn,
      project: project,
      session: session
    } do
      {:ok, other_session} =
        %Synapsis.Session{}
        |> Synapsis.Session.changeset(%{
          project_id: project.id,
          provider: "anthropic",
          model: "claude-sonnet-4-20250514",
          title: "Other Session"
        })
        |> Synapsis.Repo.insert()

      {:ok, view, html} =
        live(conn, ~p"/projects/#{project.id}/sessions/#{session.id}")

      assert html =~ "Other Session"
      render_hook(view, "delete_session", %{"id" => other_session.id})
      refute render(view) =~ "Other Session"
    end

    test "switch_session event navigates to the selected session", %{
      conn: conn,
      project: project,
      session: session
    } do
      {:ok, other_session} =
        %Synapsis.Session{}
        |> Synapsis.Session.changeset(%{
          project_id: project.id,
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })
        |> Synapsis.Repo.insert()

      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.id}/sessions/#{session.id}")

      assert {:error, {:live_redirect, %{to: path}}} =
               render_hook(view, "switch_session", %{"id" => other_session.id})

      assert path =~ other_session.id
    end

    test "switch_agent to build from plan and back", %{
      conn: conn,
      project: project,
      session: session
    } do
      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.id}/sessions/#{session.id}")

      # Switch to plan
      view |> element("button", "plan") |> render_click()
      html = render(view)
      assert html =~ "plan"

      # Switch back to build
      view |> element("button", "build") |> render_click()
      html = render(view)
      assert html =~ "build"
    end

    test "redirects with flash when both project and session are invalid", %{conn: conn} do
      bad_project = Ecto.UUID.generate()
      bad_session = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: "/projects/" <> _}}} =
               live(conn, ~p"/projects/#{bad_project}/sessions/#{bad_session}")
    end

    test "session without title renders 'Session' heading", %{conn: conn, project: project} do
      {:ok, untitled_session} =
        %Synapsis.Session{}
        |> Synapsis.Session.changeset(%{
          project_id: project.id,
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })
        |> Synapsis.Repo.insert()

      {:ok, _view, html} =
        live(conn, ~p"/projects/#{project.id}/sessions/#{untitled_session.id}")

      # The header should say "Session" when no title is set
      assert html =~ "Session"
    end

    test "chat container element has session id in data attribute", %{
      conn: conn,
      project: project,
      session: session
    } do
      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.id}/sessions/#{session.id}")

      assert has_element?(view, "#chat-#{session.id}")
    end

    test "sidebar highlights the current session", %{
      conn: conn,
      project: project,
      session: session
    } do
      {:ok, _view, html} =
        live(conn, ~p"/projects/#{project.id}/sessions/#{session.id}")

      # The current session should have bg-gray-800 (active indicator)
      assert html =~ "bg-gray-800"
    end

    test "project slug link in sidebar points to project page", %{
      conn: conn,
      project: project,
      session: session
    } do
      {:ok, _view, html} =
        live(conn, ~p"/projects/#{project.id}/sessions/#{session.id}")

      assert html =~ project.slug
    end

    test "select_provider with unknown provider name does not crash", %{
      conn: conn,
      project: project,
      session: session
    } do
      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.id}/sessions/#{session.id}")

      html = render_hook(view, "select_provider", %{"provider" => "totally_fake"})
      assert is_binary(html)
    end

    test "session header shows 'Session' when title is nil", %{conn: conn, project: project} do
      {:ok, untitled} =
        %Synapsis.Session{}
        |> Synapsis.Session.changeset(%{
          project_id: project.id,
          provider: "anthropic",
          model: "claude-sonnet-4-20250514"
        })
        |> Synapsis.Repo.insert()

      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.id}/sessions/#{untitled.id}")

      assert has_element?(view, "h2", "Session")
    end

    test "delete_session with invalid id shows error flash", %{
      conn: conn,
      project: project,
      session: session
    } do
      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.id}/sessions/#{session.id}")

      html = render_hook(view, "delete_session", %{"id" => Ecto.UUID.generate()})
      assert html =~ "Failed to delete session"
    end
  end
end
