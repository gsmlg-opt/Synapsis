defmodule Synapsis.Agent.ResolverNativeMCPFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Agent.Resolver
  alias Synapsis.{AgentConfigs, Config.Store, Toolsets}

  test "direct native selection retains ordered qualified MCP names and saved UUID policy" do
    source_id = Ecto.UUID.generate()
    names = ["synapsis::todo_read", "mcp::#{source_id}::tools::read", "clock::curr_time"]
    policy = selected_policy(source_id)

    {:ok, agent} =
      AgentConfigs.create(%{
        name: unique_name("direct"),
        tools: names,
        tool_contract_version: 1,
        config: %{"mcp_selection" => policy}
      })

    on_exit(fn -> AgentConfigs.delete(agent) end)
    assert {:ok, before} = Store.get(:agent, agent.id)

    resolved = Resolver.resolve(agent.name)

    assert resolved.tools == names
    assert resolved.mcp_selection == policy
    assert resolved.tool_contract_version === 1
    assert {:ok, ^before} = Store.get(:agent, agent.id)
  end

  test "linked native Toolset retains its ordered MCP selection and the Agent UUID policy" do
    source_id = Ecto.UUID.generate()
    names = ["clock::curr_time", "mcp::#{source_id}::tools::read", "synapsis::todo_read"]
    policy = selected_policy(source_id)

    {:ok, toolset} =
      Toolsets.create(%{
        name: unique_name("toolset"),
        tool_names: names,
        tool_contract_version: 1
      })

    on_exit(fn -> Toolsets.delete(toolset) end)

    {:ok, agent} =
      AgentConfigs.create(%{
        name: unique_name("linked"),
        tools: ["synapsis::file_read"],
        toolset_ids: [toolset.id],
        tool_contract_version: 1,
        config: %{"mcp_selection" => policy}
      })

    on_exit(fn -> AgentConfigs.delete(agent) end)
    assert {:ok, agent_before} = Store.get(:agent, agent.id)
    assert {:ok, toolset_before} = Store.get(:toolset, toolset.id)

    resolved = Resolver.resolve(agent.name)

    assert resolved.tools == names
    assert resolved.toolset_ids == [toolset.id]
    assert resolved.mcp_selection == policy
    assert resolved.tool_contract_version === 1
    assert {:ok, ^agent_before} = Store.get(:agent, agent.id)
    assert {:ok, ^toolset_before} = Store.get(:toolset, toolset.id)
  end

  defp selected_policy(source_id) do
    %{
      "default" => "selected",
      "sources" => %{source_id => %{"mode" => "selected", "tools" => ["tools::read"]}}
    }
  end

  defp unique_name(kind),
    do: "resolver-native-mcp-#{kind}-#{System.unique_integer([:positive, :monotonic])}"
end
