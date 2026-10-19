defmodule Synapsis.MCPSelectionTest do
  use ExUnit.Case, async: true

  alias Synapsis.MCPSelection

  @search %{name: "mcp:renamed:search", mcp_config_id: "one", mcp_tool_name: "search"}
  @write %{name: "mcp:renamed:write", mcp_config_id: "one", mcp_tool_name: "write"}
  @other %{name: "mcp:second:search", mcp_config_id: "two", mcp_tool_name: "search"}
  @catalog [@search, @write, @other]

  test "default all includes newly discovered tools without changing stored policy" do
    policy = %{"default" => "all", "sources" => %{}}
    assert MCPSelection.names(policy, [@search]) == [@search.name]
    assert Enum.sort(Enum.map(@catalog, & &1.name)) == MCPSelection.names(policy, @catalog)
  end

  test "a group can exclude every tool while the default includes other groups" do
    policy = %{"default" => "all", "sources" => %{"one" => %{"mode" => "none"}}}
    assert MCPSelection.names(policy, @catalog) == [@other.name]
  end

  test "a selected group includes only its raw names independent of display name" do
    policy = %{
      "default" => "selected",
      "sources" => %{"one" => %{"mode" => "selected", "tools" => ["search", "gone"]}}
    }

    assert MCPSelection.names(policy, @catalog) == [@search.name]
    assert [] = MCPSelection.names(policy, [@write, @other])
    assert policy["sources"]["one"]["tools"] == ["search", "gone"]
  end

  test "an explicit all group includes future tools when global default is selected" do
    policy = %{"default" => "selected", "sources" => %{"one" => %{"mode" => "all"}}}
    assert Enum.sort([@search.name, @write.name]) == MCPSelection.names(policy, @catalog)
  end

  test "malformed or unknown rules fail closed" do
    for policy <- [nil, %{}, %{"default" => "unknown"}, %{"default" => "all", "sources" => []}] do
      assert [] = MCPSelection.names(policy, @catalog)
    end

    policy = %{"default" => "all", "sources" => %{"one" => %{"mode" => "typo"}}}
    assert MCPSelection.names(policy, @catalog) == [@other.name]
  end

  test "policy application retains builtin tools and never falls back after explicit none" do
    agent = %{
      tools: ["file_read", @search.name],
      mcp_selection: %{"default" => "selected", "sources" => %{}}
    }

    assert %{tools: ["file_read"]} = MCPSelection.apply(agent, @catalog)
    assert %{tools: []} = MCPSelection.apply(%{agent | tools: [@search.name]}, @catalog)
  end

  test "legacy agents keep their selected names until a policy is saved" do
    agent = %{tools: ["file_read", @search.name]}
    assert ^agent = MCPSelection.apply(agent, @catalog)
  end

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
