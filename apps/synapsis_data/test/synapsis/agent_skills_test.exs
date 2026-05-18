defmodule Synapsis.AgentSkillsTest do
  use Synapsis.DataCase

  alias Synapsis.{AgentConfigs, AgentSkills, Skill, Skills}

  describe "assign_skills/2" do
    test "stores the exact skills assigned to an agent" do
      {:ok, agent} = AgentConfigs.create(%{name: "writer"})
      {:ok, first} = Skills.create(%{name: "brief", scope: "global"})
      {:ok, second} = Skills.create(%{name: "review", scope: "global"})

      assert {:ok, skills} = AgentSkills.assign_skills(agent, [first.id, second.id])
      assert Enum.map(skills, & &1.name) == ["brief", "review"]
      assert AgentSkills.list_skill_ids(agent.id) == [first.id, second.id]

      assert {:ok, skills} = AgentSkills.assign_skills(agent, [second.id])
      assert Enum.map(skills, & &1.name) == ["review"]
      assert AgentSkills.list_skill_ids(agent.id) == [second.id]
    end

    test "stores the exact agents assigned to a skill" do
      {:ok, first_agent} = AgentConfigs.create(%{name: "first-agent"})
      {:ok, second_agent} = AgentConfigs.create(%{name: "second-agent"})
      {:ok, skill} = Skills.create(%{name: "planning", scope: "global"})

      assert {:ok, agents} = AgentSkills.assign_agents(skill, [first_agent.id, second_agent.id])
      assert Enum.map(agents, & &1.name) == ["first-agent", "second-agent"]
      assert AgentSkills.list_agent_ids(skill.id) == [first_agent.id, second_agent.id]

      assert {:ok, agents} = AgentSkills.assign_agents(skill, [second_agent.id])
      assert Enum.map(agents, & &1.name) == ["second-agent"]
      assert AgentSkills.list_agent_ids(skill.id) == [second_agent.id]
    end
  end

  describe "skills context" do
    test "protects built-in skills from deletion" do
      {:ok, skill} =
        Skills.create(%{
          name: "builtin-skill",
          scope: "global",
          is_builtin: true
        })

      assert {:error, :protected} = Skills.delete(skill)
      assert %Skill{} = Skills.get(skill.id)
    end
  end
end
