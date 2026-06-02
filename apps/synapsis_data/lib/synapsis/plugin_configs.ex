defmodule Synapsis.PluginConfigs do
  @moduledoc """
  Context for plugin/MCP/LSP configurations.

  ADR-006 C4: plugin configs persist in the file-backed `Config.Store`
  (`plugins.toml`). Records round-trip as `%PluginConfig{}` structs.
  """
  alias Synapsis.{Config.Store, PluginConfig}

  @store_type :plugin

  @doc "List all plugin configs ordered by name."
  def list do
    @store_type |> Store.list() |> Enum.map(&to_struct/1) |> Enum.sort_by(& &1.name)
  end

  @doc "List plugin configs of a given type (\"mcp\" / \"lsp\" / \"custom\")."
  def list_by_type(type), do: Enum.filter(list(), &(&1.type == type))

  @doc "Plugin config names for a type."
  def names_by_type(type), do: type |> list_by_type() |> Enum.map(& &1.name)

  @doc "Get a plugin config by id."
  def get(id) do
    case Store.get(@store_type, id) do
      {:ok, map} -> to_struct(map)
      _ -> nil
    end
  end

  @doc "Get a plugin config by name + type."
  def get_by_name_type(name, type),
    do: Enum.find(list(), &(&1.name == name and &1.type == type))

  @doc "Create a plugin config."
  def create(attrs) when is_map(attrs),
    do: persist(PluginConfig.changeset(%PluginConfig{}, attrs))

  @doc "Update a plugin config."
  def update(%PluginConfig{} = config, attrs),
    do: persist(PluginConfig.changeset(config, attrs))

  @doc "Delete a plugin config."
  def delete(%PluginConfig{} = config) do
    Store.delete(@store_type, config.id)
    {:ok, config}
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

  defp ensure_id(%PluginConfig{id: nil} = r), do: %{r | id: Ecto.UUID.generate()}
  defp ensure_id(r), do: r

  defp to_struct(map) do
    %PluginConfig{}
    |> PluginConfig.changeset(map)
    |> Ecto.Changeset.apply_changes()
    |> put_id(map)
  end

  defp put_id(record, map), do: %{record | id: map["id"] || record.id}

  defp to_store_map(%PluginConfig{} = r) do
    %{
      "id" => r.id,
      "type" => r.type,
      "name" => r.name,
      "transport" => r.transport,
      "command" => r.command,
      "args" => r.args || [],
      "url" => r.url,
      "root_path" => r.root_path,
      "env" => r.env || %{},
      "settings" => r.settings || %{},
      "auto_start" => r.auto_start,
      "scope" => r.scope
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
