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
  end
end
