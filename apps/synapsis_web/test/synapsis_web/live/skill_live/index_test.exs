defmodule SynapsisWeb.SkillLive.IndexTest do
  use SynapsisWeb.ConnCase

  setup do
    Synapsis.DataCase.clear_config_store(:skill)
    :ok
  end

  describe "skills page" do
    test "mounts and renders heading", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/settings/skills")
      assert html =~ "Skills"
      assert has_element?(view, "h1", "Skills")
    end

    test "shows breadcrumb navigation", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/skills")
      assert html =~ "Settings"
    end

    test "shows create form", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/skills")
      assert html =~ "Create"
    end

    test "lists existing skills", %{conn: conn} do
      Synapsis.Skills.create(%{name: "my-skill", scope: "global", description: "A test skill"})

      {:ok, _view, html} = live(conn, ~p"/settings/skills")
      assert html =~ "my-skill"
      assert html =~ "global"
    end

    test "deletes a skill", %{conn: conn} do
      {:ok, skill} =
        Synapsis.Skills.create(%{name: "to-delete", scope: "global", description: "bye"})

      {:ok, view, html} = live(conn, ~p"/settings/skills")
      assert html =~ "to-delete"

      view
      |> element(~s(el-dm-button[phx-click="delete_skill"][phx-value-id="#{skill.id}"]))
      |> render_click()

      html = render(view)
      refute html =~ "to-delete"
    end

    test "create_skill with empty name shows error flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/skills")
      view |> form("form", %{"name" => "", "scope" => "global"}) |> render_submit()
      assert render(view) =~ "Failed to create skill"
    end

    test "create_skill navigates to skill show page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/skills")

      assert {:error, {:live_redirect, %{to: "/settings/skills/" <> _}}} =
               view
               |> form("form", %{"name" => "redirect-skill", "scope" => "global"})
               |> render_submit()
    end

    test "built-in skill does not show delete button", %{conn: conn} do
      {:ok, skill} =
        Synapsis.Skills.create(%{name: "builtin-skill", scope: "global", is_builtin: true})

      {:ok, view, html} = live(conn, ~p"/settings/skills")
      assert html =~ "builtin-skill"
      # Built-in skills should not have a delete button
      refute has_element?(
               view,
               ~s(el-dm-button[phx-click="delete_skill"][phx-value-id="#{skill.id}"])
             )
    end

    test "scope selector has global option only", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/skills")
      assert html =~ "Global"
      refute html =~ "Project"
    end

    test "heading displays Skills", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/skills")
      assert has_element?(view, "h1", "Skills")
    end

    test "skills are listed in order", %{conn: conn} do
      for name <- ["alpha-skill", "beta-skill", "gamma-skill"] do
        Synapsis.Skills.create(%{name: name, scope: "global"})
      end

      {:ok, _view, html} = live(conn, ~p"/settings/skills")
      assert html =~ "alpha-skill"
      assert html =~ "beta-skill"
      assert html =~ "gamma-skill"
    end

    test "skill links to its show page", %{conn: conn} do
      {:ok, skill} = Synapsis.Skills.create(%{name: "link-test-skill", scope: "global"})

      {:ok, _view, html} = live(conn, ~p"/settings/skills")
      assert html =~ "/settings/skills/#{skill.id}"
    end

    test "skill with global scope shows 'global' label", %{conn: conn} do
      Synapsis.Skills.create(%{name: "global-scoped", scope: "global"})

      {:ok, _view, html} = live(conn, ~p"/settings/skills")
      assert html =~ "global-scoped"
      assert html =~ "global"
    end
  end
end
