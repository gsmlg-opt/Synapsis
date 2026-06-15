defmodule Synapsis.MCPConfigs do
  @moduledoc """
  Context for MCP server configs, backed by `Config.Store` type `:mcp`.

  Records persist in the file-backed `Config.Store` (`mcp.toml`) and round-trip
  as `%MCPConfig{}` structs.
  """
  alias Synapsis.{Config.Store, MCPConfig}

  @store_type :mcp

  @doc "List all MCP configs ordered by name."
  def list do
    @store_type |> Store.list() |> Enum.map(&to_struct/1) |> Enum.sort_by(& &1.name)
  end

  @doc "List enabled MCP configs."
  def enabled, do: Enum.filter(list(), & &1.enabled)

  @doc "Get an MCP config by id."
  def get(id) do
    case Store.get(@store_type, id) do
      {:ok, map} -> to_struct(map)
      _ -> nil
    end
  end

  @doc "Get an MCP config by name."
  def get_by_name(name), do: Enum.find(list(), &(&1.name == name))

  @doc "Create an MCP config."
  def create(attrs) when is_map(attrs),
    do: persist(MCPConfig.changeset(%MCPConfig{}, attrs))

  @doc "Update an MCP config."
  def update(%MCPConfig{} = config, attrs),
    do: persist(MCPConfig.changeset(config, attrs))

  @doc "Delete an MCP config."
  def delete(%MCPConfig{} = config) do
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

  defp ensure_id(%MCPConfig{id: nil} = r), do: %{r | id: Ecto.UUID.generate()}
  defp ensure_id(%MCPConfig{} = r), do: r

  defp to_struct(map) do
    %MCPConfig{}
    |> MCPConfig.changeset(map)
    |> Ecto.Changeset.apply_changes()
    |> put_id(map)
  end

  defp put_id(record, map), do: %{record | id: map["id"] || record.id}

  defp to_store_map(%MCPConfig{} = r) do
    %{
      "id" => r.id,
      "name" => r.name,
      "transport" => r.transport,
      "enabled" => r.enabled,
      "command" => r.command,
      "args" => r.args || [],
      "env" => r.env || %{},
      "url" => r.url,
      "headers" => r.headers || %{}
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
