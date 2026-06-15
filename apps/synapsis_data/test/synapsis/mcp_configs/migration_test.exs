defmodule Synapsis.MCPConfigs.MigrationTest do
  use ExUnit.Case, async: false

  alias Synapsis.{Config.Store, MCPConfigs, MCPConfigs.Migration}

  setup do
    on_exit(fn ->
      for c <- MCPConfigs.list(), do: MCPConfigs.delete(c)
      for m <- Store.list(:plugin), do: Store.delete(:plugin, m["id"] || m[:id])
    end)

    :ok
  end

  test "migrates a legacy http mcp plugin into a streamable_http mcp config" do
    id = Ecto.UUID.generate()

    {:ok, _} =
      Store.put(:plugin, %{
        id: id,
        type: "mcp",
        name: "legacy_http",
        transport: "http",
        url: "https://example.com/mcp",
        settings: %{"headers" => %{"Authorization" => "Bearer x"}}
      })

    assert {:ok, 1} = Migration.run()

    cfg = MCPConfigs.get_by_name("legacy_http")
    assert cfg.transport == "streamable_http"
    assert cfg.url == "https://example.com/mcp"
    assert cfg.headers == %{"Authorization" => "Bearer x"}
  end

  test "is idempotent — does not duplicate already-migrated names" do
    id = Ecto.UUID.generate()

    {:ok, _} =
      Store.put(:plugin, %{
        id: id,
        type: "mcp",
        name: "legacy_stdio",
        transport: "stdio",
        command: "uvx",
        args: ["x"]
      })

    assert {:ok, 1} = Migration.run()
    assert {:ok, 0} = Migration.run()
    assert length(Enum.filter(MCPConfigs.list(), &(&1.name == "legacy_stdio"))) == 1
  end
end
