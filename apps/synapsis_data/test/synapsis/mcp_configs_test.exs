defmodule Synapsis.MCPConfigsTest do
  use ExUnit.Case, async: false

  alias Synapsis.MCPConfigs

  setup do
    on_exit(fn ->
      for c <- MCPConfigs.list(), do: MCPConfigs.delete(c)
    end)

    :ok
  end

  test "create + get_by_name round-trips a stdio config" do
    {:ok, cfg} =
      MCPConfigs.create(%{
        name: "ctx7_#{System.unique_integer([:positive])}",
        transport: "stdio",
        command: "uvx",
        args: ["mcp-server-context7"],
        env: %{"TOKEN" => "abc"},
        enabled: true
      })

    assert cfg.transport == "stdio"
    assert MCPConfigs.get_by_name(cfg.name).command == "uvx"
  end

  test "rejects unknown transport" do
    {:error, changeset} =
      MCPConfigs.create(%{name: "bad", transport: "carrier-pigeon", command: "x"})

    assert "is invalid" in errors_on(changeset).transport
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end
end
