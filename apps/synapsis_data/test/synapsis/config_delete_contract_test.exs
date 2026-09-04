defmodule Synapsis.ConfigDeleteContractTest do
  use Synapsis.DataCase, async: false

  alias Synapsis.{AgentConfigs, HeartbeatConfig, MCPConfigs, Skills, Toolsets}
  alias Synapsis.Config.Store

  @types [:agent, :heartbeat, :mcp, :skill, :toolset]

  setup do
    Enum.each(@types, &clear_config_store/1)
    on_exit(fn -> Enum.each(@types, &clear_config_store/1) end)
    :ok
  end

  test "AgentConfigs.delete/1 propagates persistence failures and keeps the config" do
    assert {:ok, agent} = AgentConfigs.create(%{name: "delete-failure-agent"})
    make_read_only(:agent)

    assert {:error, {:persist_failed, _reason}} = AgentConfigs.delete(agent)
    assert %{id: id} = AgentConfigs.get(agent.id)
    assert id == agent.id
  end

  test "HeartbeatConfig.delete_config/1 propagates persistence failures and keeps the config" do
    assert {:ok, heartbeat} =
             HeartbeatConfig.create(%{
               name: "delete-failure-heartbeat",
               schedule: "0 * * * *",
               prompt: "Check the workspace."
             })

    make_read_only(:heartbeat)

    assert {:error, {:persist_failed, _reason}} = HeartbeatConfig.delete_config(heartbeat)
    assert %{id: id} = HeartbeatConfig.get(heartbeat.id)
    assert id == heartbeat.id
  end

  test "MCPConfigs.delete/1 propagates persistence failures and keeps the config" do
    assert {:ok, config} =
             MCPConfigs.create(%{
               name: "delete-failure-mcp",
               transport: "stdio",
               command: "test-mcp"
             })

    make_read_only(:mcp)

    assert {:error, {:persist_failed, _reason}} = MCPConfigs.delete(config)
    assert %{id: id} = MCPConfigs.get(config.id)
    assert id == config.id
  end

  test "Skills.delete/1 propagates persistence failures and keeps the config" do
    assert {:ok, skill} = Skills.create(%{name: "delete-failure-skill", scope: "global"})
    make_read_only(:skill)

    assert {:error, {:persist_failed, _reason}} = Skills.delete(skill)
    assert %{id: id} = Skills.get(skill.id)
    assert id == skill.id
  end

  test "Toolsets.delete/1 propagates persistence failures and keeps the config" do
    assert {:ok, toolset} = Toolsets.create(%{name: "delete-failure-toolset"})
    make_read_only(:toolset)

    assert {:error, {:persist_failed, _reason}} = Toolsets.delete(toolset)
    assert %{id: id} = Toolsets.get(toolset.id)
    assert id == toolset.id
  end

  defp make_read_only(type) do
    type
    |> Store.file_path()
    |> File.chmod!(0o400)
  end
end
