defmodule Synapsis.AgentSkill do
  @moduledoc "Join record linking an agent configuration to an assigned skill."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_skills" do
    belongs_to(:agent_config, Synapsis.AgentConfig)
    belongs_to(:skill, Synapsis.Skill)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(agent_skill, attrs) do
    agent_skill
    |> cast(attrs, [:agent_config_id, :skill_id])
    |> validate_required([:agent_config_id, :skill_id])
    |> unique_constraint([:agent_config_id, :skill_id])
  end
end
