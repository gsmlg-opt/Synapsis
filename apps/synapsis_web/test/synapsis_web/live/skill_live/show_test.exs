defmodule SynapsisWeb.SkillLive.ShowTest do
  use SynapsisWeb.ConnCase

  setup do
    {:ok, skill} =
      %Synapsis.Skill{}
      |> Synapsis.Skill.changeset(%{
        name: "test-skill",
        scope: "global",
        description: "A test skill for show page",
        system_prompt_fragment: "You are helpful."
      })
      |> Synapsis.Repo.insert()

    {:ok, skill: skill}
  end

  describe "skill show page" do
    test "mounts and shows skill name", %{conn: conn, skill: skill} do
      {:ok, _view, html} = live(conn, ~p"/settings/skills/#{skill.id}")
      assert html =~ skill.name
    end

    test "shows description and system prompt fragment", %{conn: conn, skill: skill} do
      {:ok, _view, html} = live(conn, ~p"/settings/skills/#{skill.id}")
      assert html =~ skill.description
      assert html =~ skill.system_prompt_fragment
    end

    test "shows scope selector", %{conn: conn, skill: skill} do
      {:ok, _view, html} = live(conn, ~p"/settings/skills/#{skill.id}")
      assert html =~ "Global"
    end

    test "shows save button", %{conn: conn, skill: skill} do
      {:ok, view, _html} = live(conn, ~p"/settings/skills/#{skill.id}")
      assert has_element?(view, "button[type='submit']", "Save Changes")
    end

    test "shows Settings / Skills breadcrumb", %{conn: conn, skill: skill} do
      {:ok, _view, html} = live(conn, ~p"/settings/skills/#{skill.id}")
      assert html =~ "Settings"
      assert html =~ "Skills"
    end

    test "redirects for unknown skill id", %{conn: conn} do
      id = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: "/settings/skills"}}} =
               live(conn, ~p"/settings/skills/#{id}")
    end

    test "update_skill event saves changes", %{conn: conn, skill: skill} do
      {:ok, view, _html} = live(conn, ~p"/settings/skills/#{skill.id}")

      html =
        view
        |> form("form", %{
          "name" => skill.name,
          "description" => "Updated description",
          "system_prompt_fragment" => "Updated prompt",
          "scope" => "global"
        })
        |> render_submit()

      assert html =~ "Skill updated"
    end

    test "update_skill with empty name shows error flash", %{conn: conn, skill: skill} do
      {:ok, view, _html} = live(conn, ~p"/settings/skills/#{skill.id}")
      view |> form("form", %{"name" => "", "description" => ""}) |> render_submit()
      assert render(view) =~ "Failed to update skill"
    end
  end
end
