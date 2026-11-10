defmodule Synapsis.Agent.ResolverResourcesFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Agent.Resolver
  alias Synapsis.{AgentConfigs, Config.Store}

  test "saved resource UUID order and unrelated config survive TOML reload and resolution" do
    ids = for _ <- 1..2, do: Ecto.UUID.generate()
    ids = ids |> Enum.sort() |> Enum.reverse()
    names = ["clock::curr_time"]

    config = %{
      "mcp_resource_source_ids" => ids,
      "mcp_selection" => %{"default" => "none", "sources" => %{}},
      "unrelated" => %{"label" => "資料 α", "order" => [3, 1, 2]}
    }

    assert {:ok, saved} =
             AgentConfigs.create(%{
               name: unique_name(),
               tools: names,
               tool_contract_version: 1,
               config: config
             })

    on_exit(fn -> AgentConfigs.delete(saved) end)
    assert {:ok, before} = Store.get(:agent, saved.id)
    assert Jason.decode!(before["config"]) == config
    assert :ok = Store.reload(:agent)
    assert AgentConfigs.get(saved.id).config == config
    assert {:ok, configured} = Resolver.resolve_configured(saved.name)

    for resolved <- [Resolver.resolve(saved.name), configured] do
      assert resolved.mcp_resource_source_ids == ids
      assert resolved.tools == names
      assert resolved.tool_contract_version == 1
      assert resolved.tool_selection_sources["agent"]["mcp_resource_source_ids"] == ids
    end

    assert {:ok, ^before} = Store.get(:agent, saved.id)
    assert AgentConfigs.get(saved.id).config == config
  end

  test "tool MCP policy retains independent default-empty resource provenance" do
    source_id = Ecto.UUID.generate()
    names = ["mcp::#{source_id}::selected"]
    policy = %{"default" => "none", "sources" => %{source_id => %{"mode" => "all"}}}

    assert {:ok, saved} =
             AgentConfigs.create(%{
               name: unique_name(),
               tools: names,
               tool_contract_version: 1,
               config: %{"mcp_selection" => policy, "unrelated" => "retained"}
             })

    on_exit(fn -> AgentConfigs.delete(saved) end)
    assert :ok = Store.reload(:agent)
    assert {:ok, configured} = Resolver.resolve_configured(saved.name)

    for resolved <- [Resolver.resolve(saved.name), configured] do
      assert resolved.mcp_resource_source_ids == []
      assert resolved.tool_selection_sources["agent"]["mcp_resource_source_ids"] == []
      assert resolved.mcp_selection == policy
      assert resolved.tools == names
    end

    assert AgentConfigs.get(saved.id).config == %{
             "mcp_selection" => policy,
             "unrelated" => "retained"
           }
  end

  defp unique_name,
    do: "resolver-resources-#{System.unique_integer([:positive, :monotonic])}"
end
