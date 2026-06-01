defmodule Synapsis.Toolsets do
  @moduledoc """
  Context for managing named toolsets.

  ADR-006 C4: toolsets persist in the file-backed `Config.Store` (`toolsets.toml`).
  """
  alias Synapsis.{Config.Store, PluginConfig, Toolset}

  @store_type :toolset

  @doc "List toolsets ordered by name."
  def list do
    @store_type |> Store.list() |> Enum.map(&to_struct/1) |> Enum.sort_by(& &1.name)
  end

  @doc "Get a toolset by id."
  def get(id) do
    case Store.get(@store_type, id) do
      {:ok, map} -> to_struct(map)
      _ -> nil
    end
  end

  @doc "Get toolsets by id, preserving caller order."
  def list_by_ids(ids) when is_list(ids) do
    by_id = Map.new(list(), &{&1.id, &1})

    ids
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.flat_map(fn id -> List.wrap(Map.get(by_id, id)) end)
  end

  @doc "List configured MCP plugin sources ordered by name."
  def list_mcp_sources do
    :plugin
    |> Store.list()
    |> Enum.filter(&(&1["type"] == "mcp"))
    |> Enum.map(&plugin_to_struct/1)
    |> Enum.sort_by(& &1.name)
  end

  @doc "Create a toolset."
  def create(attrs) when is_map(attrs), do: persist(Toolset.changeset(%Toolset{}, attrs))

  @doc "Update a toolset."
  def update(%Toolset{} = toolset, attrs) when is_map(attrs),
    do: persist(Toolset.changeset(toolset, attrs))

  @doc "Delete a custom toolset."
  def delete(%Toolset{is_builtin: true}), do: {:error, :protected}

  def delete(%Toolset{} = toolset) do
    Store.delete(@store_type, toolset.id)
    {:ok, toolset}
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp persist(%Ecto.Changeset{valid?: true} = changeset) do
    record = changeset |> Ecto.Changeset.apply_changes() |> ensure_id()

    case Store.put(@store_type, to_store_map(record)) do
      :ok -> {:ok, record}
      {:ok, _} -> {:ok, record}
      error -> error
    end
  end

  defp persist(%Ecto.Changeset{} = changeset), do: {:error, changeset}

  defp ensure_id(%Toolset{id: nil} = r), do: %{r | id: Ecto.UUID.generate()}
  defp ensure_id(r), do: r

  defp to_struct(map) do
    %Toolset{} |> Toolset.changeset(map) |> Ecto.Changeset.apply_changes() |> put_id(map)
  end

  defp put_id(record, map), do: %{record | id: map["id"] || record.id}

  defp to_store_map(%Toolset{} = r) do
    %{
      "id" => r.id,
      "name" => r.name,
      "description" => r.description,
      "tool_names" => r.tool_names || [],
      "is_builtin" => r.is_builtin
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp plugin_to_struct(map) do
    %PluginConfig{} |> PluginConfig.changeset(map) |> Ecto.Changeset.apply_changes()
  end
end
