defmodule Synapsis.Skills do
  @moduledoc """
  Context for managing skill definitions and their agent assignments.

  ADR-006 C4: skills persist in the file-backed `Config.Store` (`skills.toml`).
  The agent↔skill relationship is denormalized onto the agent config
  (`config["skill_ids"]`) — node-local, no join table.
  """
  alias Synapsis.{AgentConfig, AgentConfigs, Config.Store, Skill}

  @store_type :skill

  @doc "List skills ordered by name."
  def list do
    @store_type |> Store.list() |> Enum.map(&to_struct/1) |> Enum.sort_by(& &1.name)
  end

  @doc "Get a skill by id."
  def get(id) do
    case Store.get(@store_type, id) do
      {:ok, map} -> to_struct(map)
      _ -> nil
    end
  end

  @doc "Create a skill."
  def create(attrs) when is_map(attrs), do: persist(Skill.changeset(%Skill{}, attrs))

  @doc "Update a skill."
  def update(%Skill{} = skill, attrs) when is_map(attrs),
    do: persist(Skill.changeset(skill, attrs))

  @doc "Delete a custom skill."
  def delete(%Skill{is_builtin: true}), do: {:error, :protected}

  def delete(%Skill{} = skill) do
    Store.delete(@store_type, skill.id)
    {:ok, skill}
  end

  # ── agent ↔ skill assignments (denormalized on the agent config) ────────────

  @doc "List skills assigned to an agent."
  def list_skills_for_agent(%AgentConfig{} = agent) do
    agent |> skill_ids_of() |> Enum.map(&get/1) |> Enum.reject(&is_nil/1)
  end

  @doc "List skills assigned to an agent by name."
  def list_skills_for_agent_name(name) when is_binary(name) do
    case AgentConfigs.get_by_name(name) do
      %AgentConfig{} = agent -> list_skills_for_agent(agent)
      _ -> []
    end
  end

  @doc "List skill ids assigned to an agent id."
  def list_skill_ids(agent_id) do
    case AgentConfigs.get(agent_id) do
      %AgentConfig{} = agent -> skill_ids_of(agent)
      _ -> []
    end
  end

  @doc "List agent ids a skill is assigned to."
  def list_agent_ids(skill_id) do
    AgentConfigs.list()
    |> Enum.filter(&(skill_id in skill_ids_of(&1)))
    |> Enum.map(& &1.id)
  end

  @doc "Replace the set of skills assigned to an agent."
  def assign_skills(%AgentConfig{} = agent, skill_ids) when is_list(skill_ids) do
    put_skill_ids(agent, Enum.uniq(skill_ids))
  end

  @doc "Replace the set of agents a skill is assigned to."
  def assign_agents(%Skill{id: skill_id}, agent_ids) when is_list(agent_ids) do
    targets = MapSet.new(agent_ids)

    Enum.each(AgentConfigs.list(), fn agent ->
      ids = skill_ids_of(agent)

      desired =
        if MapSet.member?(targets, agent.id),
          do: Enum.uniq([skill_id | ids]),
          else: Enum.reject(ids, &(&1 == skill_id))

      if desired != ids, do: put_skill_ids(agent, desired)
    end)

    :ok
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp skill_ids_of(%AgentConfig{config: config}) when is_map(config),
    do: Map.get(config, "skill_ids", [])

  defp skill_ids_of(_), do: []

  defp put_skill_ids(%AgentConfig{} = agent, ids) do
    config = Map.put(agent.config || %{}, "skill_ids", ids)
    AgentConfigs.update(agent, %{config: config})
  end

  defp persist(%Ecto.Changeset{valid?: true} = changeset) do
    record = changeset |> Ecto.Changeset.apply_changes() |> ensure_id()

    case Store.put(@store_type, to_store_map(record)) do
      :ok -> {:ok, record}
      {:ok, _} -> {:ok, record}
      error -> error
    end
  end

  defp persist(%Ecto.Changeset{} = changeset), do: {:error, changeset}

  defp ensure_id(%Skill{id: nil} = r), do: %{r | id: Ecto.UUID.generate()}
  defp ensure_id(r), do: r

  defp to_struct(map) do
    %Skill{} |> Skill.changeset(map) |> Ecto.Changeset.apply_changes() |> put_id(map)
  end

  defp put_id(record, map), do: %{record | id: map["id"] || record.id}

  defp to_store_map(%Skill{} = r) do
    %{
      "id" => r.id,
      "scope" => r.scope,
      "name" => r.name,
      "description" => r.description,
      "system_prompt_fragment" => r.system_prompt_fragment,
      "tool_allowlist" => r.tool_allowlist || [],
      "is_builtin" => r.is_builtin
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
