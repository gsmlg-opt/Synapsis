defmodule Synapsis.MCPSelectionTest do
  use ExUnit.Case, async: true

  alias Synapsis.MCPSelection

  test "legacy group names migrate to source UUID and keep unavailable tool selections" do
    assert %{
             "default" => "selected",
             "sources" => %{
               "one" => %{"mode" => "selected", "tools" => ["gone", "search"]}
             }
           } =
             MCPSelection.from_legacy(
               ["file_read", "mcp:renamed:search", "mcp:renamed:gone"],
               [%{id: "one", name: "renamed"}]
             )
  end
end
