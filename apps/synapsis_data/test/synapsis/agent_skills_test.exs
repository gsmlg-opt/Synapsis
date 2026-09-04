defmodule Synapsis.AgentSkillsTest do
  use Synapsis.DataCase

  alias Synapsis.{AgentConfig, AgentConfigs, AgentSkills, Skill, Skills}

  describe "assign_skills/2" do
    test "stores the exact skills assigned to an agent" do
      {:ok, agent} = AgentConfigs.create(%{name: "writer"})
      {:ok, first} = Skills.create(%{name: "brief", scope: "global"})
      {:ok, second} = Skills.create(%{name: "review", scope: "global"})

      assert {:ok, %AgentConfig{}} = AgentSkills.assign_skills(agent, [first.id, second.id])
      assert AgentSkills.list_skill_ids(agent.id) == [first.id, second.id]

      assert {:ok, %AgentConfig{}} = AgentSkills.assign_skills(agent, [second.id])
      assert AgentSkills.list_skill_ids(agent.id) == [second.id]
    end

    test "stores the exact agents assigned to a skill" do
      {:ok, first_agent} = AgentConfigs.create(%{name: "first-agent"})
      {:ok, second_agent} = AgentConfigs.create(%{name: "second-agent"})
      {:ok, skill} = Skills.create(%{name: "planning", scope: "global"})

      assert :ok = AgentSkills.assign_agents(skill, [first_agent.id, second_agent.id])

      assert Enum.sort(AgentSkills.list_agent_ids(skill.id)) ==
               Enum.sort([first_agent.id, second_agent.id])

      assert :ok = AgentSkills.assign_agents(skill, [second_agent.id])
      assert AgentSkills.list_agent_ids(skill.id) == [second_agent.id]
    end
  end

  describe "skills context" do
    test "omits locally disabled and unavailable managed skills without changing assignments" do
      suffix = System.unique_integer([:positive])
      {:ok, agent} = AgentConfigs.create(%{name: "availability-agent-#{suffix}"})

      {:ok, local} =
        Skills.create(%{
          name: "local-skill-#{suffix}",
          scope: "global",
          config_overrides: %{"backplane_available" => false}
        })

      {:ok, local_disabled} =
        Skills.create(%{
          name: "disabled-skill-#{suffix}",
          scope: "global",
          enabled: false
        })

      {:ok, managed} =
        Skills.create(%{
          name: "managed-skill-#{suffix}",
          scope: "global",
          config_overrides: %{
            "managed_by" => "backplane",
            "backplane_source_id" => "source-1",
            "backplane_available" => true
          }
        })

      {:ok, unavailable} =
        Skills.create(%{
          name: "unavailable-skill-#{suffix}",
          scope: "global",
          config_overrides: %{
            "managed_by" => "backplane",
            "backplane_source_id" => "source-1",
            "backplane_available" => false
          }
        })

      assigned = [local.id, local_disabled.id, managed.id, unavailable.id]
      assert {:ok, assigned_agent} = AgentSkills.assign_skills(agent, assigned)

      assert Enum.map(AgentSkills.list_skills_for_agent(assigned_agent), & &1.id) ==
               [local.id, managed.id]

      assert AgentSkills.list_skill_ids(assigned_agent.id) == assigned
      assert Enum.all?(assigned, &Skills.get(&1))
    end

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
