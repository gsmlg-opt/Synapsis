defmodule Synapsis.AgentSkills do
  @moduledoc "Context for assigning skills to agents."

  import Ecto.Query
  alias Synapsis.{AgentConfig, AgentConfigs, AgentSkill, Repo, Skill}

  @doc "List skills assigned to an agent config."
  def list_skills_for_agent(%AgentConfig{id: agent_id}), do: list_skills_for_agent_id(agent_id)

  @doc "List skills assigned to an agent name."
  def list_skills_for_agent_name(name) when is_binary(name) do
    case AgentConfigs.get_by_name(name) do
      %AgentConfig{} = agent_config -> list_skills_for_agent(agent_config)
      nil -> []
    end
  end

  @doc "List skill ids assigned to an agent id."
  def list_skill_ids(agent_id) do
    AgentSkill
    |> join(:inner, [agent_skill], skill in Skill, on: skill.id == agent_skill.skill_id)
    |> where([agent_skill, _skill], agent_skill.agent_config_id == ^agent_id)
    |> order_by([_agent_skill, skill], asc: skill.name)
    |> select([agent_skill, _skill], agent_skill.skill_id)
    |> Repo.all()
  end

  @doc "List agent ids assigned to a skill id."
  def list_agent_ids(skill_id) do
    AgentSkill
    |> join(:inner, [agent_skill], agent in AgentConfig,
      on: agent.id == agent_skill.agent_config_id
    )
    |> where([agent_skill, _agent], agent_skill.skill_id == ^skill_id)
    |> order_by([_agent_skill, agent], asc: agent.name)
    |> select([agent_skill, _agent], agent_skill.agent_config_id)
    |> Repo.all()
  end

  @doc "Replace all skill assignments for an agent."
  def assign_skills(%AgentConfig{id: agent_id}, skill_ids) when is_list(skill_ids) do
    skill_ids = normalize_ids(skill_ids)

    Repo.transaction(fn ->
      Repo.delete_all(
        from(agent_skill in AgentSkill, where: agent_skill.agent_config_id == ^agent_id)
      )

      Enum.each(skill_ids, fn skill_id ->
        %AgentSkill{}
        |> AgentSkill.changeset(%{agent_config_id: agent_id, skill_id: skill_id})
        |> Repo.insert(on_conflict: :nothing)
      end)

      list_skills_for_agent_id(agent_id)
    end)
  end

  @doc "Replace all agent assignments for a skill."
  def assign_agents(%Skill{id: skill_id}, agent_ids) when is_list(agent_ids) do
    agent_ids = normalize_ids(agent_ids)

    Repo.transaction(fn ->
      Repo.delete_all(from(agent_skill in AgentSkill, where: agent_skill.skill_id == ^skill_id))

      Enum.each(agent_ids, fn agent_id ->
        %AgentSkill{}
        |> AgentSkill.changeset(%{agent_config_id: agent_id, skill_id: skill_id})
        |> Repo.insert(on_conflict: :nothing)
      end)

      list_agents_for_skill_id(skill_id)
    end)
  end

  defp list_skills_for_agent_id(agent_id) do
    Skill
    |> join(:inner, [skill], agent_skill in AgentSkill, on: agent_skill.skill_id == skill.id)
    |> where([_skill, agent_skill], agent_skill.agent_config_id == ^agent_id)
    |> order_by([skill, _agent_skill], asc: skill.name)
    |> Repo.all()
  end

  defp list_agents_for_skill_id(skill_id) do
    AgentConfig
    |> join(:inner, [agent], agent_skill in AgentSkill,
      on: agent_skill.agent_config_id == agent.id
    )
    |> where([_agent, agent_skill], agent_skill.skill_id == ^skill_id)
    |> order_by([agent, _agent_skill], asc: agent.name)
    |> Repo.all()
  end

  defp normalize_ids(ids) do
    ids
    |> List.wrap()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end
end
