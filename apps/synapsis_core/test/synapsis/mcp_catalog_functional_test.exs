defmodule Synapsis.MCPCatalogFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.MCPSelection

  def metadata(tools), do: tools

  setup do
    original = Application.get_env(:synapsis_core, :mcp_source_catalog)

    on_exit(fn ->
      if original,
        do: Application.put_env(:synapsis_core, :mcp_source_catalog, original),
        else: Application.delete_env(:synapsis_core, :mcp_source_catalog)
    end)
  end

  test "source metadata is a separate read-only display catalog" do
    name = "mcp:catalog-display-#{System.unique_integer([:positive])}:echo"

    tools = [
      %{
        name: name,
        mcp_config_id: Ecto.UUID.generate(),
        mcp_tool_name: "echo",
        description: "Source tool"
      }
    ]

    Application.put_env(:synapsis_core, :mcp_source_catalog, {__MODULE__, :metadata, [tools]})

    assert MCPSelection.display_catalog() == tools
  end

  test "absent source reader contributes no display metadata" do
    Application.delete_env(:synapsis_core, :mcp_source_catalog)
    assert MCPSelection.display_catalog() == []
  end
end
