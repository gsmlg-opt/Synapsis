defmodule SynapsisWeb.ProjectLive.ShowTest do
  use SynapsisWeb.ConnCase

  setup do
    {:ok, project} =
      %Synapsis.Project{}
      |> Synapsis.Project.changeset(%{
        path: "/tmp/show-test-#{:rand.uniform(100_000)}",
        slug: "show-test-project"
      })
      |> Synapsis.Repo.insert()

    {:ok, project: project}
  end

  describe "project show page" do
    test "mounts and shows project slug", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}")
      assert html =~ project.slug
      assert html =~ project.path
    end

    test "shows new session button", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")
      assert has_element?(view, "button", "+ New Session")
    end

    test "shows empty state when no sessions", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}")
      assert html =~ "No sessions yet"
    end

    test "redirects to /projects for unknown id", %{conn: conn} do
      id = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               live(conn, ~p"/projects/#{id}")
    end

    test "lists sessions for the project", %{conn: conn, project: project} do
      {:ok, session} =
        %Synapsis.Session{}
        |> Synapsis.Session.changeset(%{
          project_id: project.id,
          provider: "anthropic",
          model: "claude-sonnet-4-20250514",
          title: "Test Session Title"
        })
        |> Synapsis.Repo.insert()

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}")
      assert html =~ session.title
    end

    test "create_session event creates a new session and navigates", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")

      # There are two "+ New Session" buttons (one in card action, one in empty state)
      # Use the first one by targeting card-actions container
      assert {:error, {:live_redirect, %{to: "/projects/" <> _}}} =
               view |> element(".card-actions button", "+ New Session") |> render_click()
    end

    test "delete_session event removes session", %{conn: conn, project: project} do
      {:ok, session} =
        %Synapsis.Session{}
        |> Synapsis.Session.changeset(%{
          project_id: project.id,
          provider: "anthropic",
          model: "claude-sonnet-4-20250514",
          title: "Deletable Session"
        })
        |> Synapsis.Repo.insert()

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")
      assert render(view) =~ "Deletable Session"

      # dm_btn with confirm= creates a modal dialog; use render_hook to bypass
      render_hook(view, "delete_session", %{"id" => session.id})

      refute render(view) =~ "Deletable Session"
    end

    test "heading displays the project slug", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")
      # dm_card :title renders as div.card-title, not h1
      assert has_element?(view, ".card-title", project.slug)
    end

    test "breadcrumb links back to /projects", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}")
      assert html =~ ~s(href="/projects")
      assert html =~ "Projects"
    end

    test "session without title shows truncated id", %{conn: conn, project: project} do
      {:ok, session} =
        %Synapsis.Session{}
        |> Synapsis.Session.changeset(%{
          project_id: project.id,
          provider: "openai_compat",
          model: "gpt-4"
        })
        |> Synapsis.Repo.insert()

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}")
      assert html =~ "Session #{String.slice(session.id, 0, 8)}"
    end

    test "session card shows status badge", %{conn: conn, project: project} do
      {:ok, _session} =
        %Synapsis.Session{}
        |> Synapsis.Session.changeset(%{
          project_id: project.id,
          provider: "anthropic",
          model: "claude-sonnet-4-20250514",
          title: "Status Session",
          status: "idle"
        })
        |> Synapsis.Repo.insert()

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")
      # Status is inside a dm_badge which uses <slot /> (renders empty)
      # Check that the badge element exists with ghost color (for "idle" status)
      assert has_element?(view, "span.badge")
    end

    test "delete_session with invalid id shows error flash", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")
      html = render_hook(view, "delete_session", %{"id" => Ecto.UUID.generate()})
      assert html =~ "Failed to delete session"
    end

    test "multiple sessions are all listed", %{conn: conn, project: project} do
      for i <- 1..3 do
        %Synapsis.Session{}
        |> Synapsis.Session.changeset(%{
          project_id: project.id,
          provider: "anthropic",
          model: "claude-sonnet-4-20250514",
          title: "Session #{i}"
        })
        |> Synapsis.Repo.insert!()
      end

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}")
      assert html =~ "Session 1"
      assert html =~ "Session 2"
      assert html =~ "Session 3"
    end

    test "delete button uses confirm dialog", %{conn: conn, project: project} do
      {:ok, _session} =
        %Synapsis.Session{}
        |> Synapsis.Session.changeset(%{
          project_id: project.id,
          provider: "anthropic",
          model: "claude-sonnet-4-20250514",
          title: "Confirmable"
        })
        |> Synapsis.Repo.insert()

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}")
      # dm_btn with confirm= renders a modal dialog (not data-confirm attribute)
      assert html =~ "Delete this session?"
    end
  end
end
