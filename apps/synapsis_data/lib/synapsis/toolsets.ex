defmodule Synapsis.Toolsets do
  @moduledoc "Context for managing named toolsets."

  import Ecto.Query
  alias Synapsis.{Repo, Toolset}

  @doc "List toolsets ordered by name."
  def list do
    Toolset
    |> order_by(:name)
    |> Repo.all()
  end

  @doc "Get a toolset by id."
  def get(id), do: Repo.get(Toolset, id)

  @doc "Create a toolset."
  def create(attrs) when is_map(attrs) do
    %Toolset{}
    |> Toolset.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Update a toolset."
  def update(%Toolset{} = toolset, attrs) when is_map(attrs) do
    toolset
    |> Toolset.changeset(attrs)
    |> Repo.update()
  end

  @doc "Delete a custom toolset."
  def delete(%Toolset{is_builtin: true}), do: {:error, :protected}

  def delete(%Toolset{} = toolset), do: Repo.delete(toolset)
end
