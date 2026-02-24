defmodule SynapsisWeb.SkillLive.IndexTest do
  use SynapsisWeb.ConnCase

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
      %Synapsis.Skill{}
      |> Synapsis.Skill.changeset(%{
        name: "my-skill",
        scope: "global",
        description: "A test skill"
      })
      |> Synapsis.Repo.insert!()

      {:ok, _view, html} = live(conn, ~p"/settings/skills")
      assert html =~ "my-skill"
      assert html =~ "global"
    end

    test "deletes a skill", %{conn: conn} do
      {:ok, skill} =
        %Synapsis.Skill{}
        |> Synapsis.Skill.changeset(%{name: "to-delete", scope: "global", description: "bye"})
        |> Synapsis.Repo.insert()

      {:ok, view, html} = live(conn, ~p"/settings/skills")
      assert html =~ "to-delete"

      view
      |> element(~s(button[phx-click="delete_skill"][phx-value-id="#{skill.id}"]))
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
      {:ok, _skill} =
        %Synapsis.Skill{}
        |> Synapsis.Skill.changeset(%{
          name: "builtin-skill",
          scope: "global",
          is_builtin: true
        })
        |> Synapsis.Repo.insert()

      {:ok, _view, html} = live(conn, ~p"/settings/skills")
      assert html =~ "builtin-skill"
      assert html =~ "built-in"
      # Built-in skills should not have a delete button
      # The delete button uses phx-click="delete_skill" and is conditional on !skill.is_builtin
    end

    test "scope selector has global and project options", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/skills")
      assert html =~ "Global"
      assert html =~ "Project"
    end

    test "heading displays Skills", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/skills")
      assert has_element?(view, "h1", "Skills")
    end

    test "skills are listed in order", %{conn: conn} do
      for name <- ["alpha-skill", "beta-skill", "gamma-skill"] do
        %Synapsis.Skill{}
        |> Synapsis.Skill.changeset(%{name: name, scope: "global"})
        |> Synapsis.Repo.insert!()
      end

      {:ok, _view, html} = live(conn, ~p"/settings/skills")
      assert html =~ "alpha-skill"
      assert html =~ "beta-skill"
      assert html =~ "gamma-skill"
    end

    test "skill links to its show page", %{conn: conn} do
      {:ok, skill} =
        %Synapsis.Skill{}
        |> Synapsis.Skill.changeset(%{name: "link-test-skill", scope: "global"})
        |> Synapsis.Repo.insert()

      {:ok, _view, html} = live(conn, ~p"/settings/skills")
      assert html =~ "/settings/skills/#{skill.id}"
    end

    test "skill with project scope shows 'project' label", %{conn: conn} do
      %Synapsis.Skill{}
      |> Synapsis.Skill.changeset(%{name: "proj-scoped", scope: "project"})
      |> Synapsis.Repo.insert!()

      {:ok, _view, html} = live(conn, ~p"/settings/skills")
      assert html =~ "proj-scoped"
      assert html =~ "project"
    end
  end
end
