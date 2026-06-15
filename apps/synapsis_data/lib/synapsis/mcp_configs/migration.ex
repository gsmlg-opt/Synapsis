defmodule Synapsis.MCPConfigs.Migration do
  @moduledoc """
  One-time migration of legacy `:plugin` (type "mcp") configs into the new
  `:mcp` store. Idempotent: skips names that already exist in the new store.
  """
  alias Synapsis.{Config.Store, MCPConfigs}

  @transport_map %{"http" => "streamable_http", "sse" => "sse", "stdio" => "stdio"}

  @doc "Returns {:ok, migrated_count}."
  def run do
    existing = MapSet.new(MCPConfigs.list(), & &1.name)

    migrated =
      :plugin
      |> Store.list()
      |> Enum.filter(&(get(&1, "type") == "mcp"))
      |> Enum.reject(&MapSet.member?(existing, get(&1, "name")))
      |> Enum.map(&migrate_one/1)
      |> Enum.count(&match?({:ok, _}, &1))

    {:ok, migrated}
  end

  defp migrate_one(legacy) do
    settings = get(legacy, "settings") || %{}

    MCPConfigs.create(%{
      name: get(legacy, "name"),
      transport: Map.get(@transport_map, get(legacy, "transport") || "stdio", "stdio"),
      enabled: get(legacy, "auto_start") || false,
      command: get(legacy, "command"),
      args: get(legacy, "args") || [],
      env: get(legacy, "env") || %{},
      url: get(legacy, "url"),
      headers: Map.get(settings, "headers", %{})
    })
  end

  defp get(map, key) when is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end
end
