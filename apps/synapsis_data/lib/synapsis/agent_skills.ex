defmodule Synapsis.AgentSkills do
  @moduledoc """
  Agent↔skill assignment API.

  ADR-006 C4: the join is denormalized onto the agent config; this module
  delegates to `Synapsis.Skills`, which owns the assignment storage.
  """
  defdelegate list_skills_for_agent(agent), to: Synapsis.Skills
  defdelegate list_skill_ids(agent_id), to: Synapsis.Skills
  defdelegate list_agent_ids(skill_id), to: Synapsis.Skills
  defdelegate assign_skills(agent, skill_ids), to: Synapsis.Skills
  defdelegate assign_agents(skill, agent_ids), to: Synapsis.Skills
end
