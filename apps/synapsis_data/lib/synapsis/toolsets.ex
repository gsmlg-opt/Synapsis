defmodule Synapsis.Toolsets do
  @moduledoc "Context for managing named toolsets."

  import Ecto.Query
  alias Synapsis.{PluginConfig, Repo, Toolset}

  @doc "List toolsets ordered by name."
  def list do
    Toolset
    |> order_by(:name)
    |> Repo.all()
  end

  @doc "Get a toolset by id."
  def get(id), do: Repo.get(Toolset, id)

  @doc "Get toolsets by id, preserving caller order."
  def list_by_ids(ids) when is_list(ids) do
    ids =
      ids
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    toolsets =
      Toolset
      |> where([toolset], toolset.id in ^ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Enum.flat_map(ids, fn id ->
      case Map.get(toolsets, id) do
        nil -> []
        toolset -> [toolset]
      end
    end)
  end

  @doc "List configured MCP plugin sources ordered by name."
  def list_mcp_sources do
    PluginConfig
    |> where([plugin], plugin.type == "mcp")
    |> order_by([plugin], asc: plugin.name)
    |> Repo.all()
  end

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
