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
  def enabled, do: Enum.filter(list(), &runtime_available?/1)

  @doc "Whether an MCP config may participate in runtime operations."
  def runtime_available?(%MCPConfig{enabled: true, config: config}) do
    config = config || %{}

    not backplane_managed?(config) or
      (Map.get(config, "backplane_available", Map.get(config, :backplane_available)) != false and
         source_connection_enabled?(config))
  end

  def runtime_available?(_config), do: false

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
    with :ok <- Store.delete(@store_type, config.id) do
      {:ok, config}
    end
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp backplane_managed?(config) do
    Map.get(config, "managed_by", Map.get(config, :managed_by)) == "backplane" or
      not is_nil(Map.get(config, "backplane_source_id", Map.get(config, :backplane_source_id)))
  end

  defp source_connection_enabled?(config) do
    case Map.get(config, "backplane_source_id", Map.get(config, :backplane_source_id)) do
      source_id when is_binary(source_id) and source_id != "" ->
        case Store.get(:backplane, source_id) do
          {:ok, connection} when is_map(connection) ->
            source_connection_available?(connection, "tools")

          _missing_or_malformed ->
            false
        end

      _missing_or_malformed ->
        false
    end
  end

  defp source_connection_available?(connection, surface) do
    with true <- Map.get(connection, "enabled", Map.get(connection, :enabled)) == true,
         {:ok, metadata} <- connection_metadata(connection),
         blocked when is_list(blocked) <- Map.get(metadata, "runtime_blocked_surfaces", []),
         true <- Enum.all?(blocked, &is_binary/1) do
      surface not in blocked
    else
      _missing_or_malformed -> false
    end
  end

  defp connection_metadata(connection) do
    case Map.get(connection, "metadata", Map.get(connection, :metadata)) do
      metadata when is_map(metadata) ->
        {:ok, metadata}

      _not_embedded ->
        case Map.get(connection, "metadata_json", Map.get(connection, :metadata_json)) do
          nil -> {:ok, %{}}
          encoded when is_binary(encoded) -> Jason.decode(encoded)
          _malformed -> {:error, :invalid_metadata}
        end
    end
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
      "headers" => r.headers || %{},
      "config" => r.config || %{}
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
