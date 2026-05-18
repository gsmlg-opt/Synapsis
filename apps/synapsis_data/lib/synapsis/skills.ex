defmodule Synapsis.Skills do
  @moduledoc "Context for managing skill definitions."

  import Ecto.Query
  alias Synapsis.{Repo, Skill}

  @doc "List skills ordered by name."
  def list do
    Skill
    |> order_by(:name)
    |> Repo.all()
  end

  @doc "Get a skill by id."
  def get(id), do: Repo.get(Skill, id)

  @doc "Create a skill."
  def create(attrs) when is_map(attrs) do
    %Skill{}
    |> Skill.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Update a skill."
  def update(%Skill{} = skill, attrs) when is_map(attrs) do
    skill
    |> Skill.changeset(attrs)
    |> Repo.update()
  end

  @doc "Delete a custom skill."
  def delete(%Skill{is_builtin: true}), do: {:error, :protected}

  def delete(%Skill{} = skill), do: Repo.delete(skill)
end
