defmodule Synapsis.Agent.ResolverDeferredToolsFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Agent.Resolver
  alias Synapsis.{AgentConfigs, Config.Store, Toolsets}

  test "explicit deferred names survive linked selection, reload and ordinary metadata edits" do
    names = ["synapsis::file_read", "clock::curr_time"]

    {:ok, toolset} =
      Toolsets.create(%{
        name: "deferred-#{Ecto.UUID.generate()}",
        tool_names: names,
        tool_contract_version: 1
      })

    {:ok, saved} =
      AgentConfigs.create(%{
        name: "deferred-#{Ecto.UUID.generate()}",
        tools: ["exec_command"],
        toolset_ids: [toolset.id],
        tool_contract_version: 1,
        config: %{"deferred_tool_names" => names, "untouched" => %{"value" => "原样"}}
      })

    on_exit(fn ->
      AgentConfigs.delete(saved)
      Toolsets.delete(toolset)
    end)

    {:ok, before} = Store.get(:agent, saved.id)
    agent = Resolver.resolve(saved.name)
    assert agent.tools == names
    assert agent.deferred_tool_names == names
    assert agent.tool_selection_sources["agent"]["deferred_tool_names"] == names
    {:ok, _} = AgentConfigs.update(saved, %{label: "Changed"})
    {:ok, after_save} = Store.get(:agent, saved.id)
    assert after_save["tools"] == before["tools"]
    assert after_save["config"] == before["config"]
    assert Resolver.resolve(saved.name).deferred_tool_names == names
  end

  test "omitted deferral preserves an explicit selected catalog without saving defaults" do
    {:ok, saved} =
      AgentConfigs.create(%{
        name: "deferred-empty-#{Ecto.UUID.generate()}",
        tools: ["clock::curr_time"],
        tool_contract_version: 1
      })

    on_exit(fn -> AgentConfigs.delete(saved) end)
    agent = Resolver.resolve(saved.name)
    assert agent.tools == ["clock::curr_time"]
    assert agent.deferred_tool_names == []
    assert agent.tool_selection_sources["agent"]["deferred_tool_names"] == []
    assert AgentConfigs.get(saved.id).config == %{}
  end
end
