defmodule SynapsisWeb.SessionLive.IndexTest do
  use SynapsisWeb.ConnCase

  setup do
    {:ok, project} =
      %Synapsis.Project{}
      |> Synapsis.Project.changeset(%{
        path: "/tmp/sess_idx_#{:rand.uniform(100_000)}",
        slug: "sess-idx"
      })
      |> Synapsis.Repo.insert()

    %{project: project}
  end

  describe "session index page" do
    test "mounts and renders session list heading", %{conn: conn, project: project} do
      {:ok, view, html} = live(conn, ~p"/projects/#{project.id}/sessions")
      assert html =~ "Sessions"
      assert has_element?(view, "h1", "Sessions")
    end

    test "shows project breadcrumb", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}/sessions")
      assert html =~ project.slug
    end

    test "renders new session button", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/sessions")
      assert has_element?(view, "button", "+ New Session")
    end

    test "lists sessions for the project", %{conn: conn, project: project} do
      {:ok, _session} =
        %Synapsis.Session{}
        |> Synapsis.Session.changeset(%{
          project_id: project.id,
          provider: "anthropic",
          model: "claude-sonnet-4-20250514",
          title: "Listed Session"
        })
        |> Synapsis.Repo.insert()

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}/sessions")
      assert html =~ "Listed Session"
      assert html =~ "anthropic/claude-sonnet-4-20250514"
    end

    test "redirects with flash on invalid project", %{conn: conn} do
      bad_id = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               live(conn, ~p"/projects/#{bad_id}/sessions")
    end

    test "toggle_new_session_form shows the create form", %{conn: conn, project: project} do
      {:ok, view, html} = live(conn, ~p"/projects/#{project.id}/sessions")
      refute html =~ "Create Session"

      view |> element("button", "+ New Session") |> render_click()
      assert render(view) =~ "Create Session"
    end

    test "toggle_new_session_form hides form when toggled twice", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/sessions")

      view |> element("button", "+ New Session") |> render_click()
      assert render(view) =~ "Create Session"

      view |> element("button", "+ New Session") |> render_click()
      refute render(view) =~ "Create Session"
    end

    test "select_model via value key updates model", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/sessions")
      view |> element("button", "+ New Session") |> render_click()

      render_hook(view, "select_model", %{"value" => "gpt-4o"})
      assert render(view) =~ "gpt-4o"
    end

    test "select_model via model key updates model", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/sessions")
      view |> element("button", "+ New Session") |> render_click()

      render_hook(view, "select_model", %{"model" => "custom-model-v2"})
      assert render(view) =~ "custom-model-v2"
    end

    test "create_session creates a session and navigates", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/sessions")
      view |> element("button", "+ New Session") |> render_click()

      assert {:error, {:live_redirect, %{to: "/projects/" <> _}}} =
               view |> element("button", "Create Session") |> render_click()
    end

    test "select_provider updates provider and model in socket", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/sessions")
      view |> element("button", "+ New Session") |> render_click()
      render_hook(view, "select_provider", %{"provider" => "anthropic"})
      html = render(view)
      assert html =~ "Create Session"
      # After selecting anthropic, the model input should show the canonical default
      assert html =~ Synapsis.Providers.default_model("anthropic")
    end

    test "select_provider sets canonical default model for openai provider", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/sessions")
      view |> element("button", "+ New Session") |> render_click()
      render_hook(view, "select_provider", %{"provider" => "openai"})
      html = render(view)
      assert html =~ Synapsis.Providers.default_model("openai")
    end

    test "shows empty session list when project has no sessions", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}/sessions")
      # No session cards should be rendered; the session list area should be empty
      refute html =~ "anthropic/"
    end

    test "session without title shows truncated id", %{conn: conn, project: project} do
      {:ok, session} =
        %Synapsis.Session{}
        |> Synapsis.Session.changeset(%{
          project_id: project.id,
          provider: "openai_compat",
          model: "gpt-4o"
        })
        |> Synapsis.Repo.insert()

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}/sessions")
      assert html =~ "Session #{String.slice(session.id, 0, 8)}"
    end

    test "session displays agent and provider/model info", %{conn: conn, project: project} do
      {:ok, _session} =
        %Synapsis.Session{}
        |> Synapsis.Session.changeset(%{
          project_id: project.id,
          provider: "google",
          model: "gemini-pro",
          agent: "plan"
        })
        |> Synapsis.Repo.insert()

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}/sessions")
      assert html =~ "google/gemini-pro"
      assert html =~ "plan"
    end

    test "heading displays Sessions", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/sessions")
      assert has_element?(view, "h1", "Sessions")
    end

    test "breadcrumb contains Projects link", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}/sessions")
      assert html =~ "Projects"
    end

    test "select_provider with unknown provider name does not crash", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/sessions")
      view |> element("button", "+ New Session") |> render_click()
      # Sending a non-existent provider name should not crash
      html = render_hook(view, "select_provider", %{"provider" => "nonexistent_provider"})
      assert is_binary(html)
    end
  end
end
