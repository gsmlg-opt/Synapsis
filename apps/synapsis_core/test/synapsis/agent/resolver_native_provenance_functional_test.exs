defmodule Synapsis.Agent.ResolverNativeProvenanceFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional
  alias Synapsis.{AgentConfigs, Toolsets}
  alias Synapsis.Agent.Resolver

  test "configured direct tools retain same-source identity and raw provenance" do
    assert {:ok, saved} =
             AgentConfigs.create(%{
               name: "provenance-#{Ecto.UUID.generate()}",
               tools: ["exec_command"],
               tool_contract_version: 1
             })

    on_exit(fn -> AgentConfigs.delete(saved) end)
    assert {:ok, resolved} = Resolver.resolve_configured(saved.name)
    assert resolved.id == saved.id
    assert resolved.tools == ["exec_command"]

    assert resolved.tool_selection_sources == %{
             "agent" => %{
               "id" => saved.id,
               "name" => saved.name,
               "tool_contract_version" => 1,
               "tool_names" => ["exec_command"],
               "toolset_ids" => [],
               "mcp_resource_source_ids" => []
             },
             "toolsets" => []
           }
  end

  test "linked UUID Toolsets supply active names and versions ahead of direct tools" do
    assert {:ok, linked} =
             Toolsets.create(%{
               name: "linked-provenance-#{Ecto.UUID.generate()}",
               tool_names: ["synapsis::todo_read"],
               tool_contract_version: 1
             })

    assert {:ok, saved} =
             AgentConfigs.create(%{
               name: "linked-agent-#{Ecto.UUID.generate()}",
               tools: ["exec_command"],
               tool_contract_version: 0,
               toolset_ids: [linked.id]
             })

    on_exit(fn ->
      AgentConfigs.delete(saved)
      Toolsets.delete(linked)
    end)

    assert {:ok, resolved} = Resolver.resolve_configured(saved.name)
    assert resolved.tools == ["synapsis::todo_read"]
    assert resolved.tool_contract_version == 1
    assert resolved.tool_selection_sources["agent"]["tool_contract_version"] == 0

    assert resolved.tool_selection_sources["toolsets"] == [
             %{
               "id" => linked.id,
               "name" => linked.name,
               "tool_contract_version" => 1,
               "tool_names" => ["synapsis::todo_read"]
             }
           ]
  end
end
