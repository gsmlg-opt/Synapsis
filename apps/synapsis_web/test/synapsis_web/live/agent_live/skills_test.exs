defmodule SynapsisWeb.AgentLive.SkillsTest do
  use SynapsisWeb.ConnCase

  alias Synapsis.{AgentConfigs, AgentSkills, Skills}

  setup do
    Synapsis.DataCase.clear_config_store(:skill)
    :ok
  end

  defp skill_by_name(name), do: Enum.find(Skills.list(), &(&1.name == name))

  describe "skills routes" do
    test "lists skills inside the Agent module shell", %{conn: conn} do
      {:ok, _} = Skills.create(%{name: "review", scope: "global"})

      {:ok, view, html} = live(conn, ~p"/agent/skills")

      assert html =~ "Skills"
      assert html =~ "review"
      assert has_element?(view, "aside", "Tools")
      assert has_element?(view, "a[href='/agent/skills/new']", "New Skill")
    end

    test "creates a skill and assigns it to agents", %{conn: conn} do
      {:ok, agent} = AgentConfigs.create(%{name: "writer", label: "Writer"})

      {:ok, view, _html} = live(conn, ~p"/agent/skills/new")

      view
      |> form("form[phx-submit='save_skill']", %{
        "skill" => %{
          "name" => "writing-style",
          "scope" => "global",
          "description" => "Writing style",
          "system_prompt_fragment" => "Use clear prose."
        },
        "agent_ids" => [agent.id]
      })
      |> render_submit()

      skill = skill_by_name("writing-style")
      assert AgentSkills.list_agent_ids(skill.id) == [agent.id]
      assert_redirect(view, ~p"/agent/skills")
    end

    test "updates a skill assignment", %{conn: conn} do
      {:ok, agent} = AgentConfigs.create(%{name: "reviewer", label: "Reviewer"})
      {:ok, skill} = Skills.create(%{name: "review-style", scope: "global"})

      {:ok, view, _html} = live(conn, ~p"/agent/skills/#{skill.id}/edit")

      view
      |> form("form[phx-submit='save_skill']", %{
        "skill" => %{
          "name" => "review-style",
          "scope" => "global",
          "description" => "Updated",
          "system_prompt_fragment" => "Review risks first."
        },
        "agent_ids" => [agent.id]
      })
      |> render_submit()

      updated = Skills.get(skill.id)
      assert updated.system_prompt_fragment == "Review risks first."
      assert AgentSkills.list_agent_ids(skill.id) == [agent.id]
      assert_redirect(view, ~p"/agent/skills")
    end

    test "removes a custom skill", %{conn: conn} do
      {:ok, skill} = Skills.create(%{name: "temporary", scope: "global"})

      {:ok, view, _html} = live(conn, ~p"/agent/skills")

      view
      |> element(~s(el-dm-button[phx-click="delete_skill"][phx-value-id="#{skill.id}"]))
      |> render_click()

      refute Skills.get(skill.id)
    end
  end
end
