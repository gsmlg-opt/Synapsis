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

      assert {:error, {:live_redirect, %{to: "/projects/" <> _}}} =
               view |> element("button", "+ New Session") |> render_click()
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
      assert has_element?(view, "[phx-value-id='#{session.id}']")

      view
      |> element("[phx-value-id='#{session.id}']")
      |> render_click()

      refute has_element?(view, "[phx-value-id='#{session.id}']")
    end
  end
end
