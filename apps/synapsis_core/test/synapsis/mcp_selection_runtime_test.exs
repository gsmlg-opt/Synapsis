defmodule Synapsis.MCPSelectionRuntimeTest do
  use ExUnit.Case, async: false

  alias Synapsis.{AgentConfigs, MCPSelection}
  alias Synapsis.Tool.Registry

  def refresh(result), do: result

  setup do
    previous = Application.get_env(:synapsis_core, :mcp_refresh)
    Application.put_env(:synapsis_core, :mcp_refresh, {__MODULE__, :refresh, [%{}]})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:synapsis_core, :mcp_refresh, previous),
        else: Application.delete_env(:synapsis_core, :mcp_refresh)
    end)

    :ok
  end

  test "a refreshed all policy binds newly discovered definitions and registrations together" do
    name = register_tool("first")
    agent = %{tools: [], mcp_selection: %{"default" => "all", "sources" => %{}}}
    first = MCPSelection.refresh_agent(agent)
    assert name in first.tools
    second_name = register_tool("second")
    second = MCPSelection.refresh_agent(agent)
    assert second_name in second.tools

    assert Enum.find(second.resolved_tools, &(&1.name == second_name)).registration ==
             second.tool_modules[second_name]
  end

  test "failed sources cannot contribute their last registered schema" do
    name = register_tool("cached")

    Application.put_env(
      :synapsis_core,
      :mcp_refresh,
      {__MODULE__, :refresh, [%{"source" => {:error, :offline}}]}
    )

    agent = %{tools: [name], mcp_selection: %{"default" => "all", "sources" => %{}}}
    refreshed = MCPSelection.refresh_agent(agent)
    refute name in refreshed.tools
    refute Map.has_key?(refreshed.tool_modules, name)
    assert {:ok, _last_registration} = Registry.lookup(name)
  end

  test "persisted explicit none overrides legacy tools and toolset selections" do
    name = register_tool("excluded")

    {:ok, config} =
      AgentConfigs.create(%{
        name: "mcp-policy-#{System.unique_integer([:positive])}",
        tools: [name],
        config: %{
          "mcp_selection" => %{
            "default" => "all",
            "sources" => %{"source" => %{"mode" => "none"}}
          }
        }
      })

    on_exit(fn -> AgentConfigs.delete(config) end)
    resolved = Synapsis.Agent.Resolver.resolve(config.name)
    assert resolved.tools == []
    assert MCPSelection.refresh_agent(resolved).resolved_tools == []
  end

  defp register_tool(raw) do
    name = "mcp:selection-test:#{raw}"

    Registry.register_process(name, self(),
      mcp_config_id: "source",
      mcp_tool_name: raw,
      description: raw,
      parameters: %{"type" => "object", "properties" => %{}},
      permission_level: :read
    )

    on_exit(fn -> Registry.unregister(name) end)
    name
  end
end
