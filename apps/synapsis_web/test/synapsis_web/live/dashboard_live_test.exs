defmodule SynapsisWeb.DashboardLiveTest do
  use SynapsisWeb.ConnCase

  setup do
    Synapsis.DataCase.clear_config_store(:agent)
    Synapsis.DataCase.clear_coord("sessions/")
    :ok
  end

  describe "dashboard page" do
    test "mounts and renders heading", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/")
      assert html =~ "Synapsis"
      assert has_element?(view, "h1", "Dashboard")
    end

    test "shows enabled agents summary", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "p", "Enabled agents")
      assert has_element?(view, "el-dm-card", "Agent sessions")
    end

    test "renders appbar navigation links", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(
               view,
               "header.appbar .appbar-trailing a[href='/agent/agents']",
               "Agents"
             )

      assert has_element?(view, "header.appbar .appbar-trailing a[href='/settings']", "Settings")
      assert has_element?(view, "header.appbar .appbar-trailing [phx-hook='ThemeSwitcher']")
      assert has_element?(view, "header.appbar .appbar-trailing input.theme-controller-item")
      assert theme_switcher_hook_source() =~ ".theme-controller-item"

      refute has_element?(view, "header.appbar a[href='/projects']")
      refute has_element?(view, "header.appbar a[href='/chat']")
      refute has_element?(view, "header.appbar a[href='/settings/providers']")
      refute has_element?(view, "header.appbar a[href='/settings/mcp']")
      refute has_element?(view, "header.appbar a[href='/settings/lsp']")
    end

    test "lists enabled agents with session counts", %{conn: conn} do
      {:ok, _agent} =
        Synapsis.AgentConfigs.create(%{
          name: "coder",
          label: "Coder",
          description: "Coding agent",
          enabled: true
        })

      {:ok, _disabled} =
        Synapsis.AgentConfigs.create(%{
          name: "paused",
          label: "Paused",
          description: "Disabled agent",
          enabled: false
        })

      put_session(%{agent: "coder", title: "Coder Session"})
      put_session(%{agent: "coder"})
      put_session(%{agent: "paused"})

      {:ok, view, html} = live(conn, ~p"/")
      assert html =~ "Coder"
      assert html =~ "Coding agent"
      assert has_element?(view, "el-dm-badge", "2")
      refute html =~ "Paused"
    end

    test "renders Synapsis in the page title", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert page_title(view) =~ "Synapsis"
    end
  end

  defp theme_switcher_hook_source do
    Path.expand("../../../assets/js/app.ts", __DIR__)
    |> File.read!()
  end

  # ADR-006 C4: write a session meta directly (no worker) for dashboard counts.
  defp put_session(attrs) do
    now = DateTime.utc_now()

    session =
      struct(
        Synapsis.Session,
        Map.merge(
          %{
            id: Ecto.UUID.generate(),
            provider: "anthropic",
            model: "claude-sonnet-4-20250514",
            status: "idle",
            config: %{},
            inserted_at: now,
            updated_at: now
          },
          attrs
        )
      )

    :ok = Synapsis.Session.Store.put_meta(session.id, Synapsis.Session.to_meta(session))
    session
  end
end
