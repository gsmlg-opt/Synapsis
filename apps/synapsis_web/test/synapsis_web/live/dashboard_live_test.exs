defmodule SynapsisWeb.DashboardLiveTest do
  use SynapsisWeb.ConnCase

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
        %Synapsis.AgentConfig{}
        |> Synapsis.AgentConfig.changeset(%{
          name: "coder",
          label: "Coder",
          description: "Coding agent",
          enabled: true
        })
        |> Synapsis.Repo.insert()

      {:ok, _disabled} =
        %Synapsis.AgentConfig{}
        |> Synapsis.AgentConfig.changeset(%{
          name: "paused",
          label: "Paused",
          description: "Disabled agent",
          enabled: false
        })
        |> Synapsis.Repo.insert()

      {:ok, _session} =
        %Synapsis.Session{}
        |> Synapsis.Session.changeset(%{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514",
          agent: "coder",
          title: "Coder Session"
        })
        |> Synapsis.Repo.insert()

      {:ok, _second_session} =
        %Synapsis.Session{}
        |> Synapsis.Session.changeset(%{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514",
          agent: "coder"
        })
        |> Synapsis.Repo.insert()

      {:ok, _disabled_session} =
        %Synapsis.Session{}
        |> Synapsis.Session.changeset(%{
          provider: "anthropic",
          model: "claude-sonnet-4-20250514",
          agent: "paused"
        })
        |> Synapsis.Repo.insert()

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
end
