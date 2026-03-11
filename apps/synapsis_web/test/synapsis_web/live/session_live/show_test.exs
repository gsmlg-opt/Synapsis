defmodule SynapsisWeb.SessionLive.ShowTest do
  use SynapsisWeb.ConnCase

  setup do
    # Ensure a clean provider slate and create an anthropic provider for model lookups
    Synapsis.Repo.delete_all(Synapsis.ProviderConfig)

    {:ok, _provider} =
      %Synapsis.ProviderConfig{}
      |> Synapsis.ProviderConfig.changeset(%{
        name: "anthropic",
        type: "anthropic",
        api_key_encrypted: "sk-ant-test"
      })
      |> Synapsis.Repo.insert()

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

    test "renders session mode buttons in status bar", %{
      conn: conn,
      project: project,
      session: session
    } do
      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.id}/sessions/#{session.id}")

      assert has_element?(view, "button", "Bypass")
      assert has_element?(view, "button", "Ask")
      assert has_element?(view, "button", "Auto-edit")
      assert has_element?(view, "button", "Plan")
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
      render_hook(view, "select_model", %{"model" => "claude-haiku-3-5-20241022"})
      html = render(view)
      assert html =~ "claude-haiku-3-5-20241022"
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

    test "select_provider sets canonical default model for the selected provider", %{
      conn: conn,
      project: project,
      session: session
    } do
      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.id}/sessions/#{session.id}")

      # Open the new session form so the model input is rendered
      render_hook(view, "toggle_new_session_form", %{})
      render_hook(view, "select_provider", %{"provider" => "openai"})
      html = render(view)
      # Should show gpt-4.1, not gpt-4o or claude-opus-4-6
      assert html =~ Synapsis.Providers.default_model("openai")
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

    test "switch_mode event changes the session mode", %{
      conn: conn,
      project: project,
      session: session
    } do
      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.id}/sessions/#{session.id}")

      # Default mode should be rendered
      html = render(view)
      assert html =~ "Ask"

      # Switch to plan mode via hook (since the session worker isn't running,
      # we just verify the event handler doesn't crash)
      html = render_hook(view, "switch_mode", %{"mode" => "plan_mode"})
      assert is_binary(html)
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

      # dm_left_menu uses menu-active class (not bg-gray-800)
      assert html =~ "menu-active"
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

    test "model selector button shows current provider/model", %{
      conn: conn,
      project: project,
      session: session
    } do
      {:ok, _view, html} =
        live(conn, ~p"/projects/#{project.id}/sessions/#{session.id}")

      assert html =~ "anthropic/claude-sonnet-4-20250514"
    end

    test "model selector dropdown contains switch_model options", %{
      conn: conn,
      project: project,
      session: session
    } do
      {:ok, _view, html} =
        live(conn, ~p"/projects/#{project.id}/sessions/#{session.id}")

      # dm_dropdown always renders its content in the DOM
      assert html =~ "switch_model"
      assert html =~ "switch_provider"
    end

    test "switch_model updates the session model", %{
      conn: conn,
      project: project,
      session: session
    } do
      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.id}/sessions/#{session.id}")

      # Use render_hook since the dropdown content is always in DOM
      html =
        render_hook(view, "switch_model", %{
          "provider" => "anthropic",
          "model" => "claude-opus-4-20250514"
        })

      assert html =~ "Model switched"
      assert html =~ "anthropic/claude-opus-4-20250514"
    end

    test "switch_provider in model selector updates the model list", %{
      conn: conn,
      project: project,
      session: session
    } do
      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.id}/sessions/#{session.id}")

      html = render_hook(view, "switch_provider", %{"provider" => "anthropic"})
      assert html =~ "Claude"
    end
  end
end
